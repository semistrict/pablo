import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct VideoCaptureInfo {
    let frame: CGRect
    let displayID: UInt32?
    let width: Int
    let height: Int
    let displayScale: Double
    let framesPerSecond: Int
}

enum VideoCaptureScope {
    case application(pid_t)
    case display(UInt32?)
}

struct PreparedVideoWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
}

struct VideoCaptureLifecycle {
    enum Phase {
        case idle
        case starting
        case capturing
        case stopping
        case stopped
    }

    private(set) var phase: Phase = .idle

    mutating func beginStart() {
        phase = .starting
    }

    mutating func completeStart() {
        if phase == .starting {
            phase = .capturing
        }
    }

    mutating func failStart() {
        phase = .stopped
    }

    mutating func beginStop() -> Bool {
        guard phase == .starting || phase == .capturing else { return false }
        phase = .stopping
        return true
    }

    mutating func completeStop() {
        phase = .stopped
    }

    mutating func streamStopped(with error: Error) -> Error? {
        phase = .stopped
        return Self.isUserStopped(error) ? nil : error
    }

    static func isAlreadyStopped(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain &&
            error.code == SCStreamError.Code.attemptToStopStreamState.rawValue
    }

    static func isUnavailableSource(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && [
            SCStreamError.Code.noDisplayList.rawValue,
            SCStreamError.Code.noCaptureSource.rawValue,
        ].contains(error.code)
    }

    private static func isUserStopped(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain &&
            error.code == SCStreamError.Code.userStopped.rawValue
    }
}

enum VideoWriterPipeline {
    static func prepare(
        outputURL: URL,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        expectsMediaDataInRealTime: Bool = true
    ) throws -> PreparedVideoWriter {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(2_000_000, width * height * 4),
            AVVideoExpectedSourceFrameRateKey: framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = expectsMediaDataInRealTime
        guard writer.canAdd(input) else {
            throw RecordingError.capture("Could not configure the video encoder.")
        }
        writer.add(input)

        // AVFoundation raises an Objective-C exception if this adaptor is created
        // after startWriting(), so keep this ordering inside the tested factory.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.startWriting() else {
            throw RecordingError.capture(
                "Could not start the video encoder: \(writer.error?.localizedDescription ?? "unknown error")"
            )
        }
        return PreparedVideoWriter(writer: writer, input: input, adaptor: adaptor)
    }
}

final class VideoRecorder: NSObject, RecordingVideoTrackCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let display: RecordingDisplay
    private let applicationPID: pid_t?
    private let outputURL: URL
    private let clock: SessionClock
    private let framesPerSecond: Int
    private let videoQueue = DispatchQueue(label: "pablo.video-recorder", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lifecycle = VideoCaptureLifecycle()
    private var didStartSession = false
    private var _firstFrameTimestampNs: UInt64?
    private var captureError: Error?
    private var paused = false
    private var earliestTimestampNs: UInt64 = 0

    init(display: RecordingDisplay, applicationPID: pid_t?, outputURL: URL, clock: SessionClock, framesPerSecond: Int = 30) {
        self.display = display
        self.applicationPID = applicationPID
        self.outputURL = outputURL
        self.clock = clock
        self.framesPerSecond = framesPerSecond
    }

    var firstFrameTimestampNs: UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _firstFrameTimestampNs
    }

    var captureEnded: Bool {
        stateLock.withLock { lifecycle.phase == .stopped }
    }

    func start() async throws -> VideoCaptureInfo {
        earliestTimestampNs = clock.nowNanoseconds()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let sourceDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw RecordingError.capture("Display \(display.id) is not available for recording.")
        }
        let frame = sourceDisplay.frame
        let displayID = display.id
        let scale = display.scale
        let filter: SCContentFilter
        if let applicationPID {
            guard let application = content.applications.first(where: { $0.processID == applicationPID }) else {
                throw RecordingError.capture(
                    "The selected application is not available for recording."
                )
            }
            // An application filter follows new windows without changing the
            // recording target or accidentally including a different app.
            filter = SCContentFilter(display: sourceDisplay, including: [application], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: sourceDisplay, excludingApplications: [], exceptingWindows: [])
        }
        let width = even(Int((frame.width * scale).rounded()))
        let height = even(Int((frame.height * scale).rounded()))

        let preparedWriter = try VideoWriterPipeline.prepare(
            outputURL: outputURL,
            width: width,
            height: height,
            framesPerSecond: framesPerSecond
        )
        assetWriter = preparedWriter.writer
        writerInput = preparedWriter.input
        pixelBufferAdaptor = preparedWriter.adaptor

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.2, *) {
            configuration.includeChildWindows = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        stateLock.withLock {
            self.stream = stream
            lifecycle.beginStart()
        }
        do {
            try await stream.startCapture()
            stateLock.withLock { lifecycle.completeStart() }
        } catch {
            stateLock.withLock { lifecycle.failStart() }
            throw error
        }

        return VideoCaptureInfo(
            frame: frame,
            displayID: displayID,
            width: width,
            height: height,
            displayScale: scale,
            framesPerSecond: framesPerSecond
        )
    }

    func stop(at timestampNs: UInt64) async throws {
        var firstError = await stopStreamIfNeeded()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                videoQueue.async { [weak self] in
                    guard let self, let writer = self.assetWriter, let input = self.writerInput else {
                        continuation.resume()
                        return
                    }
                    guard self.didStartSession else {
                        writer.cancelWriting()
                        try? FileManager.default.removeItem(at: self.outputURL)
                        continuation.resume()
                        return
                    }
                    writer.endSession(atSourceTime: CMTime(value: Int64(clamping: timestampNs), timescale: 1_000_000_000))
                    input.markAsFinished()
                    writer.finishWriting {
                        if writer.status == .failed {
                            continuation.resume(
                                throwing: writer.error ?? RecordingError.capture("Video encoding failed.")
                            )
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        } catch {
            // Encoder failures must not be hidden by an expected source loss.
            firstError = error
        }
        if let captureError = stateLock.withLock({ self.captureError }) {
            firstError = firstError ?? captureError
        }
        if let firstError { throw firstError }
    }

    func cancel() async {
        _ = await stopStreamIfNeeded()
        await withCheckedContinuation { continuation in
            videoQueue.async { [weak self] in
                self?.assetWriter?.cancelWriting()
                continuation.resume()
            }
        }
        try? FileManager.default.removeItem(at: outputURL)
    }

    func pause() {
        stateLock.withLock {
            guard !paused else { return }
            paused = true
        }
    }

    func resume() {
        stateLock.withLock {
            guard paused else { return }
            paused = false
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.withLock {
            if let unexpectedError = lifecycle.streamStopped(with: error) {
                captureError = unexpectedError
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferDataIsReady(sampleBuffer),
              isCompleteFrame(sampleBuffer),
              let input = writerInput,
              let adaptor = pixelBufferAdaptor,
              let writer = assetWriter,
              writer.status == .writing,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard !stateLock.withLock({ paused }) else { return }
        let hostTime = CMTimeConvertScale(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            timescale: 1_000_000_000,
            method: .default
        )
        guard hostTime.isNumeric, hostTime.value >= 0,
              let timestampNs = clock.timestamp(forHostNanoseconds: UInt64(hostTime.value)),
              timestampNs >= earliestTimestampNs else { return }
        let presentationTime = CMTime(value: Int64(clamping: timestampNs), timescale: 1_000_000_000)

        if !didStartSession {
            didStartSession = true
            writer.startSession(atSourceTime: presentationTime)
            stateLock.lock()
            _firstFrameTimestampNs = timestampNs
            stateLock.unlock()
        }
        if input.isReadyForMoreMediaData, !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            stateLock.lock()
            captureError = writer.error ?? RecordingError.capture("A video frame could not be encoded.")
            stateLock.unlock()
        }
    }

    private func stopStreamIfNeeded() async -> Error? {
        let streamToStop = stateLock.withLock { () -> SCStream? in
            guard lifecycle.beginStop() else {
                stream = nil
                return nil
            }
            return stream
        }
        guard let streamToStop else { return nil }

        do {
            try await streamToStop.stopCapture()
            stateLock.withLock {
                lifecycle.completeStop()
                stream = nil
            }
            return nil
        } catch {
            stateLock.withLock {
                lifecycle.completeStop()
                stream = nil
            }
            return VideoCaptureLifecycle.isAlreadyStopped(error) ? nil : error
        }
    }

    private func even(_ value: Int) -> Int {
        max(2, value - value % 2)
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let statusRawValue = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: statusRawValue) else {
            return false
        }
        return status == .complete
    }
}
