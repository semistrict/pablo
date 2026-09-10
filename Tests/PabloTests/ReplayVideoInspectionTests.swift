import Foundation
import CoreGraphics
import Testing
@testable import PabloCore
@testable import PabloApp

private let inspectionCanvas = RecordingRect(x: -400, y: 100, width: 800, height: 600)

private func inspectionNode(
    _ id: String, frame: RecordingRect = inspectionCanvas,
    parent: String? = nil, role: String = "AXButton", depth: Int = 1
) -> ReplayAccessibilityNode {
    ReplayAccessibilityNode(AXNode(
        id: id, parentID: parent, childIDs: [], role: role, subrole: nil,
        title: id, label: nil, value: nil, identifier: nil, help: nil,
        enabled: true, focused: false,
        position: .init(x: frame.x, y: frame.y), size: .init(width: frame.width, height: frame.height)
    ), depth: depth)
}

private func inspectionStep(_ id: Int = 0, app: String = "A", nodes: [ReplayAccessibilityNode]) -> ReplayAccessibilityStep {
    ReplayAccessibilityStep(
        id: id, timestampNs: UInt64(id + 1) * 1_000_000_000, reason: "periodic", kind: "full",
        applicationID: app, applicationName: app, applicationBundleIdentifier: nil,
        applicationPID: 1, rootID: nil, nodes: nodes, changedNodes: nodes,
        changedNodeIDs: Set(nodes.map(\.id)), removedNodeIDs: [], totalNodeCount: nodes.count, truncated: false
    )
}

private func inspectionWindow(
    _ app: String = "A", frame: RecordingRect = inspectionCanvas, z: UInt32 = 0, visible: Bool = true
) -> RecordingWindow {
    RecordingWindow(id: "\(app)-\(z)", applicationID: app, systemWindowID: z, title: nil,
                    frame: frame, layer: 0, isOnScreen: visible, zOrder: z)
}

@Test func videoInspectionPicksSmallestElementAndMapsFocusedNegativeOrigin() throws {
    let button = inspectionNode("button", frame: .init(x: -200, y: 250, width: 80, height: 40), parent: "window")
    let window = inspectionNode("window", role: "AXWindow", depth: 0)
    let step = inspectionStep(nodes: [window, button])
    let full = ReplayVideoInspection(viewport: inspectionCanvas, steps: [step], windows: [inspectionWindow()], recordedFrames: [inspectionCanvas])
    #expect(full.element(at: CGPoint(x: 0.3, y: 0.28))?.id == "button")
    let focused = RecordingRect(x: -220, y: 200, width: 200, height: 200)
    let crop = ReplayVideoInspection(viewport: focused, steps: [step], windows: [inspectionWindow()], recordedFrames: [inspectionCanvas])
    let hit = try #require(crop.element(at: CGPoint(x: 0.3, y: 0.3)))
    #expect(hit.id == "button")
    #expect(hit.region == CGRect(x: 0.1, y: 0.25, width: 0.4, height: 0.2))
    #expect(crop.element(at: CGPoint(x: -0.1, y: 0.3)) == nil)
}

@Test func videoInspectionRespectsOcclusionAndMissingGeometry() {
    let back = inspectionStep(app: "A", nodes: [inspectionNode("back")])
    let front = inspectionStep(app: "B", nodes: [inspectionNode("front")])
    let windows = [inspectionWindow("A", z: 2), inspectionWindow("B", z: 0)]
    let point = CGPoint(x: 0.5, y: 0.5)
    let covered = ReplayVideoInspection(viewport: inspectionCanvas, steps: [back, front], windows: windows, recordedFrames: [inspectionCanvas])
    #expect(covered.element(at: point)?.id == "front")
    let unavailable = ReplayVideoInspection(viewport: inspectionCanvas, steps: [back], windows: windows, recordedFrames: [inspectionCanvas])
    #expect(unavailable.element(at: point) == nil)
    let hidden = ReplayVideoInspection(viewport: inspectionCanvas, steps: [back], windows: [inspectionWindow(visible: false)], recordedFrames: [inspectionCanvas])
    #expect(hidden.element(at: point) == nil)
    let noVideo = ReplayVideoInspection(viewport: inspectionCanvas, steps: [back], windows: [inspectionWindow()], recordedFrames: [])
    #expect(noVideo.element(at: point) == nil)
    let invalid = inspectionNode("invalid", frame: .init(x: 0, y: 0, width: .nan, height: 20))
    let noBounds = ReplayVideoInspection(viewport: inspectionCanvas, steps: [inspectionStep(nodes: [invalid])], windows: [inspectionWindow()], recordedFrames: [inspectionCanvas])
    #expect(noBounds.element(at: point) == nil)
}

@Test func videoInspectionRejectsCoveredWindowsWithinSameAppAndBreaksTiesByDepth() {
    let backFrame = RecordingRect(x: -300, y: 150, width: 500, height: 500)
    let nodes = [
        inspectionNode("front-window", role: "AXWindow", depth: 0),
        inspectionNode("back-window", frame: backFrame, role: "AXWindow", depth: 0),
        inspectionNode("covered-button", frame: .init(x: -80, y: 350, width: 20, height: 20), parent: "back-window"),
        inspectionNode("front-container", parent: "front-window", depth: 1),
        inspectionNode("front-leaf", parent: "front-container", depth: 2)
    ]
    let inspection = ReplayVideoInspection(viewport: inspectionCanvas, steps: [inspectionStep(nodes: nodes)],
        windows: [inspectionWindow(), inspectionWindow(frame: backFrame, z: 1)], recordedFrames: [inspectionCanvas])
    #expect(inspection.element(at: CGPoint(x: 0.41, y: 0.43))?.id == "front-leaf")
}

@Test func videoInspectionUsesLastObservedStateAndActiveVideoOnly() {
    let steps = [inspectionStep(nodes: [inspectionNode("old")]), inspectionStep(1, nodes: [inspectionNode("new")])]
    let workspace = WorkspaceSnapshotRecord(schemaVersion: 3, timestampNs: 1_000_000_000, reason: "initial",
        frontmostApplicationID: "A", applications: [], windows: [inspectionWindow()],
        appearedApplicationIDs: [], removedApplicationIDs: [], appearedWindowIDs: [], removedWindowIDs: [])
    let track = RecordingVideoTrack(id: "VIDEO-001", displayID: 1, file: "video.mov", frame: inspectionCanvas,
        width: 1600, height: 1200, displayScale: 2, framesPerSecond: 30, startedTimestampNs: 0,
        firstFrameTimestampNs: 500_000_000, endedTimestampNs: 3_000_000_000, endReason: .recordingStopped)
    let recording = ReplayRecording(packageURL: URL(fileURLWithPath: "/tmp/example.pablo"),
        videoTracks: [.init(metadata: track, url: URL(fileURLWithPath: "/tmp/video.mov"))],
        scopeName: "Display", scope: .display, selectedApplicationID: nil, selectedDisplayID: 1,
        captureFrame: inspectionCanvas, startedAt: "", durationNs: 3_000_000_000,
        firstFrameTimestampNs: 500_000_000, captureWidth: 1600, captureHeight: 1200, framesPerSecond: 30,
        inputEvents: [], accessibilitySteps: steps, workspaceSteps: [workspace], annotations: [])
    func hit(_ time: Double) -> String? {
        recording.videoInspection(atVideoTime: time, viewport: inspectionCanvas).element(at: CGPoint(x: 0.5, y: 0.5))?.id
    }
    #expect(hit(0) == nil)
    #expect(hit(0.5) == "old")
    #expect(hit(1.49) == "old")
    #expect(hit(1.5) == "new")
    #expect(hit(2.5) == nil)
}

@Test func videoInspectionDisambiguatesIdenticalWindowBounds() {
    let nodes = [
        inspectionNode("Front", role: "AXWindow", depth: 0),
        inspectionNode("Back", role: "AXWindow", depth: 0),
        inspectionNode("front-content", parent: "Front"),
        inspectionNode("covered-button", frame: .init(x: -10, y: 390, width: 20, height: 20), parent: "Back")
    ]
    func hit(title: String?) -> String? {
        let window = RecordingWindow(id: "window", applicationID: "A", systemWindowID: 1,
            title: title, frame: inspectionCanvas, layer: 0, isOnScreen: true, zOrder: 0)
        return ReplayVideoInspection(viewport: inspectionCanvas, steps: [inspectionStep(nodes: nodes)],
            windows: [window], recordedFrames: [inspectionCanvas]).element(at: CGPoint(x: 0.5, y: 0.5))?.id
    }
    #expect(hit(title: "Front") == "front-content")
    #expect(hit(title: nil) == nil)
    #expect(hit(title: "Unmatched") == nil)
}

@MainActor
@Test func pinningVideoElementKeepsPlayheadAndDoesNotCreateMarkup() throws {
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-inspection-\(UUID().uuidString).pablo")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: package) }
    let manifest = testManifest()
    try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
    let node = AXNode(id: "button", parentID: nil, childIDs: [], role: "AXButton", subrole: nil,
        title: "Save", label: nil, value: nil, identifier: nil, help: nil, enabled: true, focused: false,
        position: .init(x: 10, y: 20), size: .init(width: 50, height: 50))
    let snapshot = AXSnapshotRecord(schemaVersion: 3, timestampNs: 100_000_000, reason: "initial", kind: "full",
        application: testApplication, rootID: node.id, upserts: [node], removed: [], truncated: false)
    try PabloProtobufCodec.encode(snapshot).write(to: package.appendingPathComponent("accessibility.pb"))
    let window = RecordingWindow(id: "window", applicationID: testApplication.id, systemWindowID: 1,
        title: nil, frame: manifest.capture.frame, layer: 0, isOnScreen: true, zOrder: 0)
    let workspace = WorkspaceSnapshotRecord(schemaVersion: 3, timestampNs: 0, reason: "initial",
        frontmostApplicationID: testApplication.id, applications: [testApplication], windows: [window],
        appearedApplicationIDs: [], removedApplicationIDs: [], appearedWindowIDs: [], removedWindowIDs: [])
    try PabloProtobufCodec.encode(workspace).write(to: package.appendingPathComponent("workspace.pb"))
    try Data().write(to: package.appendingPathComponent("events.pb"))
    try Data().write(to: package.appendingPathComponent("video.mov"))
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: package, directory: package.deletingLastPathComponent()))
    model.seek(to: 0.65)
    let element = try #require(model.videoInspection.element(at: CGPoint(x: 0.5, y: 0.5)))
    model.pinVideoElement(element)
    #expect(model.currentVideoTime == 0.65)
    #expect(model.selectedNodeID == "button")
    #expect(model.selectedStep?.timestampNs == 100_000_000)
    #expect(!model.isPlaying)
    #expect(model.draftTraceSamples.isEmpty)
    #expect(model.annotations.isEmpty)
    #expect(model.selectedNodeVideoRegion != nil)
    model.seek(to: model.duration)
    #expect(model.selectedNodeVideoRegion == nil)
    model.togglePlayback()
    #expect(model.currentVideoTime == 0)
    #expect(model.draftTraceSamples.isEmpty)
}
