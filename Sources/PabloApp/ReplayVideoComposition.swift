import AVFoundation
import PabloCore
import SwiftUI

/// One player supplies the clock for every display track. Selecting a window
/// only changes the view onto this composition, never the transport time.
@MainActor
enum ReplayVideoComposition {
    static func makeItem(recording: ReplayRecording) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        let bounds = recording.captureFrame
        let scale = min(
            Double(recording.captureWidth) / max(bounds.width, 1),
            Double(recording.captureHeight) / max(bounds.height, 1)
        )
        videoComposition.renderSize = CGSize(width: recording.captureWidth, height: recording.captureHeight)
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(recording.framesPerSecond))
        let duration = CMTime(
            seconds: max(0.001, recording.videoTime(forTimestampNs: recording.durationNs ?? 0)),
            preferredTimescale: 1_000_000_000
        )
        var layers: [AVMutableVideoCompositionLayerInstruction] = []
        for track in recording.videoTracks {
            try Task.checkCancellation()
            guard let first = track.metadata.firstFrameTimestampNs else { continue }
            let asset = AVURLAsset(url: track.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecordingError.capture("Video track \(track.id) has no readable video.")
            }
            let sourceDuration = try await asset.load(.duration)
            let start = CMTime(seconds: recording.videoTime(forTimestampNs: first), preferredTimescale: 1_000_000_000)
            let end = CMTime(
                seconds: recording.videoTime(forTimestampNs: track.metadata.endedTimestampNs ?? recording.durationNs ?? first),
                preferredTimescale: 1_000_000_000
            )
            let length = CMTimeMinimum(sourceDuration, CMTimeSubtract(end, start))
            guard length.isNumeric, length > .zero else { continue }
            if layers.isEmpty {
                // Empty composition ranges render black but AVPlayer can clamp seeking
                // to the last media sample. An invisible sample keeps the session clock
                // seekable through gaps and the evidence-only tail of a recording.
                guard let clock = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw RecordingError.capture("Could not prepare the recording timeline.")
                }
                let sample = CMTimeRange(start: .zero, duration: CMTimeMinimum(sourceDuration, videoComposition.frameDuration))
                try clock.insertTimeRange(sample, of: source, at: .zero)
                clock.scaleTimeRange(sample, toDuration: duration)
                let clockLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: clock)
                clockLayer.setOpacity(0, at: .zero)
                layers.append(clockLayer)
            }
            guard let destination = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw RecordingError.capture("Could not prepare video track \(track.id).")
            }
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: start)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: destination)
            let frame = track.metadata.frame
            let transform = CGAffineTransform(
                a: frame.width * scale / Double(track.metadata.width), b: 0,
                c: 0, d: frame.height * scale / Double(track.metadata.height),
                tx: (frame.x - bounds.x) * scale, ty: (frame.y - bounds.y) * scale
            )
            layer.setTransform(transform, at: .zero)
            layer.setOpacity(0, at: .zero)
            layer.setOpacity(1, at: start)
            layer.setOpacity(0, at: end)
            layers.append(layer)
        }
        guard !layers.isEmpty else {
            throw RecordingError.capture("This recording contains no captured video frames.")
        }
        if composition.duration < duration {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: duration - composition.duration))
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        instruction.layerInstructions = layers
        videoComposition.instructions = [instruction]
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }
}

struct ReplayVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: VideoSurfaceView, context: Context) {
        view.playerLayer.player = player
    }
}

final class VideoSurfaceView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resize
    }

    required init?(coder: NSCoder) { nil }
}
