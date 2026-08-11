import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PabloCore

@Suite("Video writer pipeline", .serialized)
struct VideoWriterPipelineTests {
    @Test("Writer setup does not abort")
    func writerSetupDoesNotAbort() async {
        await #expect(processExitsWith: .success) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pablo-writer-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: url) }

            let pipeline = try VideoWriterPipeline.prepare(
                outputURL: url,
                width: 640,
                height: 480,
                framesPerSecond: 30,
                expectsMediaDataInRealTime: false
            )
            pipeline.writer.cancelWriting()
        }
    }

    @Test("Synthetic frames produce a readable movie")
    func syntheticFramesProduceReadableMovie() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pablo-frames-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = try VideoWriterPipeline.prepare(
            outputURL: url,
            width: 640,
            height: 480,
            framesPerSecond: 30,
            expectsMediaDataInRealTime: false
        )
        pipeline.writer.startSession(atSourceTime: .zero)
        let pixelBuffer = try makePixelBuffer(width: 640, height: 480)

        #expect(pipeline.adaptor.append(pixelBuffer, withPresentationTime: .zero))
        #expect(
            pipeline.adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: 1, timescale: 30)
            )
        )
        pipeline.input.markAsFinished()
        await pipeline.writer.finishWriting()

        #expect(pipeline.writer.status == .completed)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        #expect(tracks.count == 1)
        #expect(CMTimeCompare(duration, .zero) > 0)
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw VideoTestError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VideoTestError.missingBaseAddress
        }
        memset(baseAddress, 0x4A, CVPixelBufferGetDataSize(pixelBuffer))
        return pixelBuffer
    }
}

private enum VideoTestError: Error {
    case pixelBufferCreationFailed(CVReturn)
    case missingBaseAddress
}
