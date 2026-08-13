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
    private let selectedApplication: TargetApplication?
    private let applicationRegistry = RecordingApplicationRegistry()
    public let packageURL: URL
    private let clock = SessionClock()
    private var inputWriter: ProtobufStreamWriter<InputEventRecord>?
    private var accessibilityWriter: ProtobufStreamWriter<AXSnapshotRecord>?
    private var workspaceWriter: ProtobufStreamWriter<WorkspaceSnapshotRecord>?
    private var video: VideoRecorder?
    private var accessibility: AccessibilityRecorder?
    private var input: InputRecorder?
    private var manifest: RecordingManifest?
    private var manifestURL: URL?
    public private(set) var state: State = .idle

    public var scopeName: String {
        selectedApplication?.name ?? options.displayID.map { "Display \($0)" } ?? "Entire Screen"
    }
    public var durationNs: UInt64 { clock.nowNanoseconds() }
    public var captureEnded: Bool { video?.captureEnded ?? false }
    public var applicationIDs: [String] { applicationRegistry.allApplications().map(\.id) }

    public init(options: RecordOptions) throws {
        self.options = options
        selectedApplication = options.scope == .application ? try TargetApplication.resolve(
            pid: options.pid,
            bundleIdentifier: options.bundleIdentifier,
            appName: options.appName
        ) : nil
        packageURL = options.outputURL ?? Self.defaultOutputURL()
    }

    public func start() async throws {
        guard state == .idle else { return }
        try checkPermissions()
        try preparePackage()

        let inputURL = packageURL.appendingPathComponent("events.pb")
        let accessibilityURL = packageURL.appendingPathComponent("accessibility.pb")
        let workspaceURL = packageURL.appendingPathComponent("workspace.pb")
        let videoURL = packageURL.appendingPathComponent("video.mov")
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        self.manifestURL = manifestURL

        let inputWriter = try ProtobufStreamWriter<InputEventRecord>(
            url: inputURL,
            encode: PabloProtobufCodec.encode
        )
        let accessibilityWriter = try ProtobufStreamWriter<AXSnapshotRecord>(
            url: accessibilityURL,
            encode: PabloProtobufCodec.encode
        )
        let workspaceWriter = try ProtobufStreamWriter<WorkspaceSnapshotRecord>(
            url: workspaceURL,
            encode: PabloProtobufCodec.encode
        )
        self.inputWriter = inputWriter
        self.accessibilityWriter = accessibilityWriter
        self.workspaceWriter = workspaceWriter
        let captureScope: VideoCaptureScope = if let selectedApplication {
            .application(selectedApplication.pid)
        } else {
            .display(options.displayID)
        }
        let video = VideoRecorder(
            captureScope: captureScope,
            outputURL: videoURL,
            clock: clock,
            framesPerSecond: options.framesPerSecond
        )
        self.video = video
        let accessibility = AccessibilityRecorder(
            scope: options.scope,
            selectedPID: selectedApplication?.pid,
            registry: applicationRegistry,
            captureFrame: { [weak video] in video?.captureFrame },
            clock: clock,
            writer: accessibilityWriter,
            workspaceWriter: workspaceWriter,
            interval: options.snapshotInterval
        )
        self.accessibility = accessibility

        do {
            let capture = try await video.start()
            let selectedDescriptor = selectedApplication.flatMap {
                applicationRegistry.application(for: $0.pid, timestampNs: 0)
            }
            let manifest = RecordingManifest(
                schemaVersion: RecordingManifest.currentSchemaVersion,
                startedAt: ISO8601DateFormatter.recordingFormatter.string(from: Date()),
                endedAt: nil,
                durationNs: nil,
                scope: .init(
                    kind: options.scope,
                    selectedApplicationID: selectedDescriptor?.id,
                    selectedDisplayID: capture.displayID
                ),
                displays: RecordingDisplays.current(),
                applications: applicationRegistry.allApplications(),
                capture: .init(
                    frame: RecordingRect(
                        x: capture.frame.origin.x,
                        y: capture.frame.origin.y,
                        width: capture.frame.width,
                        height: capture.frame.height
                    ),
                    displayScale: capture.displayScale,
                    width: capture.width,
                    height: capture.height,
                    framesPerSecond: capture.framesPerSecond,
                    firstFrameTimestampNs: nil
                ),
                files: [
                    "video": "video.mov",
                    "events": "events.pb",
                    "accessibility": "accessibility.pb",
                    "workspace": "workspace.pb",
                ]
            )
            self.manifest = manifest
            try writeManifest(manifest, to: manifestURL)
            accessibility.start()

            let input = InputRecorder(
                scope: options.scope,
                selectedPID: selectedApplication?.pid,
                registry: applicationRegistry,
                clock: clock,
                includeText: options.captureText,
                targetFrame: { [weak video] in video?.captureFrame }
            ) { record in
                do {
                    try inputWriter.append(record)
                } catch {
                    Self.writeError("Input write failed: \(error)")
                }
                if record.type != "mouseMove" && record.type != "mouseDrag" {
                    accessibility.requestSnapshot(
                        reason: "input:\(record.type)",
                        applicationPID: record.targetPID.map(pid_t.init)
                    )
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

    public func recordAutomationAction(
        _ trace: PabloAutomationActionTrace,
        actionTargetPID: pid_t?
    ) throws {
        guard state == .recording || state == .paused else {
            throw RecordingError.capture("There is no active recording for the automation trace.")
        }
        guard let inputWriter else {
            throw RecordingError.capture("The recording event stream is unavailable.")
        }
        let timestampNs = clock.nowNanoseconds()
        let applicationID = actionTargetPID.flatMap {
            applicationRegistry.application(for: $0, timestampNs: timestampNs)?.id
        }
        try inputWriter.append(.automationAction(
            timestampNs: timestampNs,
            targetPID: actionTargetPID,
            applicationID: applicationID,
            trace: trace.resolvingApplicationID(applicationID)
        ))
    }

    public func stop() async throws {
        guard state == .recording || state == .paused else { return }
        input?.stop()
        accessibility?.stop()

        var firstError: Error?
        do { try await video?.stop() } catch { firstError = error }
        do { try inputWriter?.close() } catch { firstError = firstError ?? error }
        do { try accessibilityWriter?.close() } catch { firstError = firstError ?? error }
        do { try workspaceWriter?.close() } catch { firstError = firstError ?? error }

        manifest?.endedAt = ISO8601DateFormatter.recordingFormatter.string(from: Date())
        manifest?.durationNs = clock.nowNanoseconds()
        manifest?.capture.firstFrameTimestampNs = video?.firstFrameTimestampNs
        manifest?.applications = applicationRegistry.allApplications()
        manifest?.displays = RecordingDisplays.current()
        if let manifest, let manifestURL {
            do { try writeManifest(manifest, to: manifestURL) } catch { firstError = firstError ?? error }
        }
        state = .stopped
        if let firstError { throw firstError }
    }

    public func run() async throws {
        try await start()
        print("Recording \(scopeName)")
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
        try? workspaceWriter?.close()
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
