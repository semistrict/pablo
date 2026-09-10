import AppKit
import AVFoundation
import Testing
@testable import PabloCore

@MainActor
@Test(
    "Native application video includes existing and newly opened windows",
    .enabled(if: ProcessInfo.processInfo.environment["PABLO_CAPTURE_SMOKE_TEST"] == "1",
             "Opt-in desktop capture test; requires an existing screen recording grant")
)
func applicationVideoCapturesNewWindows() async throws {
    guard CGPreflightScreenCaptureAccess() else {
        throw RecordingError.permission("The capture test requires an existing Screen Recording grant.")
    }
    let application = NSApplication.shared
    let previousPolicy = application.activationPolicy()
    _ = application.setActivationPolicy(.accessory)
    let screen = try #require(NSScreen.main)
    let displayID = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).uint32Value
    var windows: [NSWindow] = []
    defer {
        for window in windows { window.close() }
        _ = application.setActivationPolicy(previousPolicy)
    }
    func makeWindow(_ index: Int, color: NSColor) -> NSWindow {
        let frame = NSRect(x: screen.visibleFrame.minX + 40 + Double(index) * 200,
                           y: screen.visibleFrame.minY + 80, width: 160, height: 140)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Pablo capture test \(index + 1)"
        window.isReleasedWhenClosed = false
        window.backgroundColor = color
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }
    let red = makeWindow(0, color: .red)
    let blue = makeWindow(1, color: .blue)
    try await Task.sleep(for: .milliseconds(300))
    let redFrame = try observedFrame(red)
    let blueFrame = try observedFrame(blue)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-window-capture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = SessionClock()
    let capture = VideoCaptureSession(
        scope: .application(getpid()), directory: directory, clock: clock, framesPerSecond: 30,
        automaticallyRefresh: false
    )
    do {
        try await capture.start()
        let deadline = Date().addingTimeInterval(8)
        while capture.capture.videoTracks.first(where: { $0.displayID == displayID })?.firstFrameTimestampNs == nil,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(400))
        let initialTime = clock.nowNanoseconds()
        try await Task.sleep(for: .milliseconds(200))
        let green = makeWindow(2, color: .green)
        try await Task.sleep(for: .milliseconds(500))
        let addedTime = clock.nowNanoseconds()
        let greenFrame = try observedFrame(green)
        try await Task.sleep(for: .milliseconds(200))
        red.close()
        try await Task.sleep(for: .milliseconds(500))
        let removedTime = clock.nowNanoseconds()
        try await Task.sleep(for: .milliseconds(200))
        blue.close()
        green.close()
        try await Task.sleep(for: .milliseconds(500))
        let emptyTime = clock.nowNanoseconds()
        try await Task.sleep(for: .milliseconds(200))
        let reopened = makeWindow(1, color: .blue)
        try await Task.sleep(for: .milliseconds(500))
        let reopenedTime = clock.nowNanoseconds()
        _ = try observedFrame(reopened)
        try await Task.sleep(for: .milliseconds(200))
        try await capture.stop()

        let track = try #require(capture.capture.videoTracks.first(where: { $0.displayID == displayID }))
        let first = try #require(track.firstFrameTimestampNs)
        let url = directory.appendingPathComponent(URL(fileURLWithPath: track.file).lastPathComponent)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func image(at timestamp: UInt64) async throws -> CGImage {
            let seconds = Double(timestamp - first) / 1_000_000_000
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)).image
        }
        func point(_ frame: CGRect) -> CGPoint {
            CGPoint(x: (frame.midX - track.frame.x) * Double(track.width) / track.frame.width,
                    y: (frame.midY - track.frame.y) * Double(track.height) / track.frame.height)
        }
        let redPoint = point(redFrame)
        let bluePoint = point(blueFrame)
        let greenPoint = point(greenFrame)
        let initial = try await image(at: initialTime)
        try expectPixel(initial, x: Int(redPoint.x), y: Int(redPoint.y), red: true)
        try expectPixel(initial, x: Int(bluePoint.x), y: Int(bluePoint.y), blue: true)
        let added = try await image(at: addedTime)
        try expectPixel(added, x: Int(redPoint.x), y: Int(redPoint.y), red: true)
        try expectPixel(added, x: Int(greenPoint.x), y: Int(greenPoint.y), green: true)
        let removed = try await image(at: removedTime)
        try expectPixel(removed, x: Int(redPoint.x), y: Int(redPoint.y), black: true)
        try expectPixel(removed, x: Int(bluePoint.x), y: Int(bluePoint.y), blue: true)
        let empty = try await image(at: emptyTime)
        try expectPixel(empty, x: Int(bluePoint.x), y: Int(bluePoint.y), black: true)
        try expectPixel(empty, x: Int(greenPoint.x), y: Int(greenPoint.y), black: true)
        let reopenedImage = try await image(at: reopenedTime)
        try expectPixel(reopenedImage, x: Int(bluePoint.x), y: Int(bluePoint.y), blue: true)
    } catch {
        await capture.cancel()
        throw error
    }
}

@MainActor
private func observedFrame(_ window: NSWindow) throws -> CGRect {
    try #require(RecordingWindowObservation.current(includeOffscreen: true)
        .first(where: { $0.pid == getpid() && $0.systemID == UInt32(window.windowNumber) })?.frame)
}
