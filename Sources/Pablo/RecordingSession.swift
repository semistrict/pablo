import ApplicationServices
import Foundation

public final class RecordingSession {
    public enum State {
        case idle
        case recording
        case paused
        case stopped
    }

    private let options: RecordOptions
    private let target: TargetApplication
    public let packageURL: URL
    private let clock = SessionClock()
    private var inputWriter: JSONLWriter<InputEventRecord>?
    private var accessibilityWriter: JSONLWriter<AXSnapshotRecord>?
    private var video: VideoRecorder?
    private var accessibility: AccessibilityRecorder?
    private var input: InputRecorder?
    private var manifest: RecordingManifest?
    private var manifestURL: URL?
    public private(set) var state: State = .idle

    public var targetName: String { target.name }
    public var durationNs: UInt64 { clock.nowNanoseconds() }
    public var captureEnded: Bool { video?.captureEnded ?? false }

    public init(options: RecordOptions) throws {
        self.options = options
        target = try TargetApplication.resolve(
            pid: options.pid,
            bundleIdentifier: options.bundleIdentifier,
            appName: options.appName
        )
        packageURL = options.outputURL ?? Self.defaultOutputURL()
    }

    public func start() async throws {
        guard state == .idle else { return }
        try checkPermissions()
        try preparePackage()

        let inputURL = packageURL.appendingPathComponent("events.jsonl")
        let accessibilityURL = packageURL.appendingPathComponent("accessibility.jsonl")
        let videoURL = packageURL.appendingPathComponent("video.mov")
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        self.manifestURL = manifestURL

        let inputWriter = try JSONLWriter<InputEventRecord>(url: inputURL)
        let accessibilityWriter = try JSONLWriter<AXSnapshotRecord>(url: accessibilityURL)
        self.inputWriter = inputWriter
        self.accessibilityWriter = accessibilityWriter
        let video = VideoRecorder(
            targetPID: target.pid,
            outputURL: videoURL,
            clock: clock,
            framesPerSecond: options.framesPerSecond
        )
        self.video = video
        let accessibility = AccessibilityRecorder(
            pid: target.pid,
            clock: clock,
            writer: accessibilityWriter,
            interval: options.snapshotInterval
        )
        self.accessibility = accessibility

        do {
            let capture = try await video.start()
            let manifest = RecordingManifest(
                schemaVersion: 1,
                startedAt: ISO8601DateFormatter.recordingFormatter.string(from: Date()),
                endedAt: nil,
                durationNs: nil,
                target: .init(
                    pid: target.pid,
                    bundleIdentifier: target.bundleIdentifier,
                    name: target.name
                ),
                capture: .init(
                    displayScale: capture.displayScale,
                    width: capture.width,
                    height: capture.height,
                    framesPerSecond: capture.framesPerSecond,
                    firstFrameTimestampNs: nil
                ),
                files: [
                    "video": "video.mov",
                    "events": "events.jsonl",
                    "accessibility": "accessibility.jsonl",
                ]
            )
            self.manifest = manifest
            try writeManifest(manifest, to: manifestURL)
            accessibility.start()

            let input = InputRecorder(
                targetPID: target.pid,
                clock: clock,
                includeText: options.captureText,
                targetFrame: { [weak video] in video?.windowFrame }
            ) { record in
                do {
                    try inputWriter.append(record)
                } catch {
                    Self.writeError("Input write failed: \(error)")
                }
                if record.type != "mouseMove" && record.type != "mouseDrag" {
                    accessibility.requestSnapshot(reason: "input:\(record.type)")
                }
            }
            self.input = input
            try input.start()
            state = .recording
        } catch {
            await cleanUpAfterFailedStart()
            state = .stopped
            throw error
        }
    }

    public func pause() {
        guard state == .recording else { return }
        input?.pause()
        accessibility?.pause()
        video?.pause()
        clock.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        clock.resume()
        video?.resume()
        accessibility?.resume()
        input?.resume()
        state = .recording
    }

    public func stop() async throws {
        guard state == .recording || state == .paused else { return }
        input?.stop()
        accessibility?.stop()

        var firstError: Error?
        do { try await video?.stop() } catch { firstError = error }
        do { try inputWriter?.close() } catch { firstError = firstError ?? error }
        do { try accessibilityWriter?.close() } catch { firstError = firstError ?? error }

        manifest?.endedAt = ISO8601DateFormatter.recordingFormatter.string(from: Date())
        manifest?.durationNs = clock.nowNanoseconds()
        manifest?.capture.firstFrameTimestampNs = video?.firstFrameTimestampNs
        if let manifest, let manifestURL {
            do { try writeManifest(manifest, to: manifestURL) } catch { firstError = firstError ?? error }
        }
        state = .stopped
        if let firstError { throw firstError }
    }

    public func run() async throws {
        try await start()
        print("Recording \(target.name) (PID \(target.pid))")
        print("Writing \(packageURL.path)")
        print(options.duration == nil ? "Press Control-C to stop." : "Recording for \(options.duration!) seconds.")
        await waitUntilStopped(after: options.duration)
        try await stop()
    }

    private func cleanUpAfterFailedStart() async {
        input?.stop()
        accessibility?.stop()
        await video?.cancel()
        try? inputWriter?.close()
        try? accessibilityWriter?.close()
    }

    private func checkPermissions() throws {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            throw RecordingError.permission(
                "Accessibility access is required. Enable Pablo in System Settings > Privacy & Security > Accessibility, then try again."
            )
        }
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
            throw RecordingError.permission(
                "Input Monitoring access is required. Enable Pablo in System Settings > Privacy & Security > Input Monitoring, then try again."
            )
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecordingError.permission(
                "Screen Recording access is required. Enable Pablo in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
            )
        }
    }

    private func preparePackage() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: packageURL.path) {
            let contents = try manager.contentsOfDirectory(atPath: packageURL.path)
            guard contents.isEmpty else {
                throw RecordingError.usage("Output already exists and is not empty: \(packageURL.path)")
            }
        } else {
            try manager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        }
    }

    private func writeManifest(_ manifest: RecordingManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func waitUntilStopped(after duration: TimeInterval?) async {
        await withCheckedContinuation { continuation in
            let semaphore = DispatchSemaphore(value: 0)
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            interrupt.setEventHandler { semaphore.signal() }
            terminate.setEventHandler { semaphore.signal() }
            interrupt.resume()
            terminate.resume()
            if let duration {
                DispatchQueue.global().asyncAfter(deadline: .now() + duration) { semaphore.signal() }
            }
            DispatchQueue.global().async {
                semaphore.wait()
                interrupt.cancel()
                terminate.cancel()
                continuation.resume()
            }
        }
    }

    private static func defaultOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Recording-\(formatter.string(from: Date())).pablo"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(name)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
