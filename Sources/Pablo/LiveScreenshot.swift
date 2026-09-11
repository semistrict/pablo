import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public struct PabloLiveScreenshot: Codable, Sendable {
    public let observationID: UUID
    public let frameReference: String
    public let windowID: String
    public let captureWindowID: UInt32
    public let frame: ReplayAccessibilityFrame
    public let width: Int
    public let height: Int
    public let mimeType: String
    public let pngBase64: String
    /// Host monotonic timestamps bound image collection; AX and pixels are not atomic.
    public let startedAtUptimeNanoseconds: UInt64
    public let finishedAtUptimeNanoseconds: UInt64
}

struct LiveScreenshotWindow: Equatable {
    let id: UInt32
    let pid: Int32
    let frame: CGRect
    let title: String?
}

enum LiveScreenshotMatching {
    static func match(pid: Int32, frame: CGRect, title: String?, windows: [LiveScreenshotWindow]) throws -> UInt32 {
        let matching = windows.filter { candidate in
            candidate.pid == pid && candidate.frame == frame &&
                (title == nil || title?.isEmpty == true || candidate.title == title)
        }
        guard matching.count == 1, let window = matching.first else {
            throw RecordingError.staleContext("The accessible window could not be uniquely matched to a capture window. Observe it again before requesting an image.")
        }
        return window.id
    }
}

@MainActor
enum LiveScreenshotCapture {
    struct Image {
        let captureWindowID: UInt32
        let frame: CGRect
        let width: Int
        let height: Int
        let pngBase64: String
        let startedAt: UInt64
        let finishedAt: UInt64
    }

    static func capture(pid: Int32, frame: CGRect, title: String?, validate: () throws -> Void) async throws -> Image {
        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingError.permission("Screen Recording access is required for a live screenshot. Enable Pablo in System Settings > Privacy & Security > Screen & System Audio Recording.")
        }
        try validate()
        let start = DispatchTime.now().uptimeNanoseconds
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        try validate()
        let id = try LiveScreenshotMatching.match(pid: pid, frame: frame, title: title, windows: content.windows.map {
            .init(id: $0.windowID, pid: $0.owningApplication?.processID ?? 0, frame: $0.frame, title: $0.title)
        })
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw RecordingError.staleContext("The selected capture window disappeared.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Bound pixel memory and the base64 response independently of display scale.
        let scale = min(1, 2_048 / max(frame.width, frame.height))
        config.width = max(1, Int(frame.width * scale))
        config.height = max(1, Int(frame.height * scale))
        config.scalesToFit = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        try validate()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RecordingError.capture("Could not encode the live screenshot.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 6 * 1_024 * 1_024 else {
            throw RecordingError.capture("The live screenshot exceeds the bounded PNG response size.")
        }
        return .init(captureWindowID: id, frame: frame, width: image.width, height: image.height,
                     pngBase64: (data as Data).base64EncodedString(), startedAt: start,
                     finishedAt: DispatchTime.now().uptimeNanoseconds)
    }
}
