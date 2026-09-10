import CoreGraphics
import Foundation

public enum RecordingVideoTrackEndReason: String, Codable, Sendable {
    case recordingStopped
    case displayUnavailable
    case displayChanged
    case captureStopped
    case failed
}

public struct RecordingVideoTrack: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayID: UInt32
    public let file: String
    public let frame: RecordingRect
    public let width: Int
    public let height: Int
    public let displayScale: Double
    public let framesPerSecond: Int
    public let startedTimestampNs: UInt64
    public var firstFrameTimestampNs: UInt64?
    public var endedTimestampNs: UInt64?
    public var endReason: RecordingVideoTrackEndReason?

    public func contains(timestampNs: UInt64) -> Bool {
        guard let firstFrameTimestampNs, timestampNs >= firstFrameTimestampNs else { return false }
        return endedTimestampNs.map { timestampNs < $0 } ?? true
    }

    func validate() throws {
        guard !id.isEmpty, frame.isValid,
              (1...Int(Int32.max)).contains(width), (1...Int(Int32.max)).contains(height),
              displayScale.isFinite, displayScale > 0,
              (1...Int(Int32.max)).contains(framesPerSecond),
              firstFrameTimestampNs.map({ $0 >= startedTimestampNs }) ?? true,
              endedTimestampNs.map({ $0 >= (firstFrameTimestampNs ?? startedTimestampNs) }) ?? true else {
            throw RecordingError.capture("The recording contains an invalid video track.")
        }
    }
}

extension RecordingRect {
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var isValid: Bool {
        [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }

    public func normalizedRect(for rect: RecordingRect) -> CGRect {
        guard isValid else { return .zero }
        return CGRect(
            x: (rect.x - x) / width, y: (rect.y - y) / height,
            width: rect.width / width, height: rect.height / height
        )
    }

    public func normalizedPoint(x: Double, y: Double, from source: RecordingRect) -> CGPoint {
        guard isValid else { return .zero }
        return CGPoint(
            x: (source.x + x * source.width - self.x) / width,
            y: (source.y + y * source.height - self.y) / height
        )
    }
}

extension RecordingManifest.Capture {
    static func native(tracks: [RecordingVideoTrack], framesPerSecond: Int) -> Self {
        let bounds = tracks.reduce(CGRect.null) { $0.union($1.frame.cgRect) }
        let frame = bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
        let scale = tracks.map(\.displayScale).max() ?? 1
        return Self(
            frame: RecordingRect(frame),
            displayScale: scale,
            width: max(2, Int(ceil(frame.width * scale))),
            height: max(2, Int(ceil(frame.height * scale))),
            framesPerSecond: framesPerSecond,
            firstFrameTimestampNs: tracks.compactMap(\.firstFrameTimestampNs).min(),
            videoTracks: tracks
        )
    }
}
