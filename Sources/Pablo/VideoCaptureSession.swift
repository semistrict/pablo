import AppKit
import Foundation

protocol RecordingVideoTrackCapturing: AnyObject {
    var firstFrameTimestampNs: UInt64? { get }
    var captureEnded: Bool { get }
    func start() async throws -> VideoCaptureInfo
    func stop(at timestampNs: UInt64) async throws
    func cancel() async
    func pause()
    func resume()
}

/// Owns the set of display tracks for one recording. Window membership is the
/// application filter's responsibility; display topology is this module's.
@MainActor
final class VideoCaptureSession {
    typealias RecorderFactory = (RecordingDisplay, pid_t?, URL, SessionClock, Int) -> any RecordingVideoTrackCapturing

    private struct ActiveTrack {
        let display: RecordingDisplay
        var metadata: RecordingVideoTrack
        let recorder: any RecordingVideoTrackCapturing
    }

    private final class FrameStore: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CGRect?
        func read() -> CGRect? { lock.withLock { value } }
        func write(_ frame: CGRect?) { lock.withLock { value = frame } }
    }

    private let scope: VideoCaptureScope
    private let directory: URL
    private let clock: SessionClock
    private let framesPerSecond: Int
    private let displays: () -> [RecordingDisplay]
    private let makeRecorder: RecorderFactory
    private let automaticallyRefresh: Bool
    private let selectedDisplayID: UInt32?
    private nonisolated let frameStore = FrameStore()
    private var active: [UInt32: ActiveTrack] = [:]
    private var finished: [RecordingVideoTrack] = []
    private var nextTrack = 1
    private var running = false
    private var paused = false
    private var monitor: Task<Void, Never>?
    private var terminalError: Error?
    private var stoppedByCapture = false

    init(
        scope: VideoCaptureScope,
        directory: URL,
        clock: SessionClock,
        framesPerSecond: Int,
        displays: @escaping () -> [RecordingDisplay] = RecordingDisplays.current,
        automaticallyRefresh: Bool = true,
        makeRecorder: @escaping RecorderFactory = { display, pid, url, clock, fps in
            VideoRecorder(display: display, applicationPID: pid, outputURL: url, clock: clock, framesPerSecond: fps)
        }
    ) {
        self.scope = scope
        self.directory = directory
        self.clock = clock
        self.framesPerSecond = framesPerSecond
        self.displays = displays
        self.makeRecorder = makeRecorder
        self.automaticallyRefresh = automaticallyRefresh
        if case .display(let id) = scope { selectedDisplayID = id ?? CGMainDisplayID() }
        else { selectedDisplayID = nil }
    }

    nonisolated var captureFrame: CGRect? { frameStore.read() }

    var captureEnded: Bool { stoppedByCapture || terminalError != nil }

    var capture: RecordingManifest.Capture {
        let tracks = finished + active.values.map { track in
            var metadata = track.metadata
            metadata.firstFrameTimestampNs = track.recorder.firstFrameTimestampNs
            return metadata
        }
        return .native(tracks: tracks.sorted { $0.id < $1.id }, framesPerSecond: framesPerSecond)
    }

    func start() async throws {
        guard !running else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        running = true
        do {
            try await refreshDisplays()
            guard !active.isEmpty else {
                throw RecordingError.capture("There is no display available for recording.")
            }
        } catch {
            await cancel()
            throw error
        }
        guard automaticallyRefresh else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self, self.running else { return }
                do { try await self.refreshDisplays() }
                catch {
                    if !Task.isCancelled { self.terminalError = error }
                    return
                }
                if self.captureEnded { return }
            }
        }
    }

    func refreshDisplays() async throws {
        guard running, !captureEnded else { return }
        let desired = displays().filter { selectedDisplayID == nil || $0.id == selectedDisplayID }
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        for id in active.keys.sorted() {
            guard let track = active[id] else { continue }
            guard let display = desiredByID[id] else {
                try await finish(id, reason: .displayUnavailable)
                continue
            }
            if track.display.frame != display.frame || track.display.scale != display.scale {
                try await finish(id, reason: .displayChanged)
            } else if track.recorder.captureEnded {
                // A system/user stop is terminal. Never silently restart a
                // stream after the user ends sharing from the system UI.
                stoppedByCapture = true
                return
            }
        }
        for display in desired.sorted(by: { $0.id < $1.id }) where active[display.id] == nil {
            guard running, !Task.isCancelled else { return }
            let id = String(format: "VIDEO-%03d", nextTrack)
            nextTrack += 1
            let file = "video/\(id).mov"
            let pid: pid_t? = if case .application(let pid) = scope { pid } else { nil }
            let recorder = makeRecorder(
                display, pid, directory.appendingPathComponent("\(id).mov"), clock, framesPerSecond
            )
            if paused { recorder.pause() }
            let started = clock.nowNanoseconds()
            do {
                let info = try await recorder.start()
                guard running, !Task.isCancelled else {
                    await recorder.cancel()
                    return
                }
                // Pause can change while ScreenCaptureKit starts the stream.
                if paused { recorder.pause() } else { recorder.resume() }
                let metadata = RecordingVideoTrack(
                    id: id, displayID: display.id, file: file,
                    frame: RecordingRect(info.frame), width: info.width, height: info.height,
                    displayScale: info.displayScale, framesPerSecond: info.framesPerSecond,
                    startedTimestampNs: started, firstFrameTimestampNs: recorder.firstFrameTimestampNs,
                    endedTimestampNs: nil, endReason: nil
                )
                active[display.id] = ActiveTrack(display: display, metadata: metadata, recorder: recorder)
            } catch {
                await recorder.cancel()
                throw error
            }
        }
        if let selectedDisplayID, let track = active[selectedDisplayID] {
            frameStore.write(track.metadata.frame.cgRect)
        }
    }

    func pause() {
        paused = true
        for track in active.values { track.recorder.pause() }
    }

    func resume() {
        for track in active.values { track.recorder.resume() }
        paused = false
    }

    func stop() async throws {
        running = false
        monitor?.cancel()
        await monitor?.value
        monitor = nil
        var error = terminalError
        for id in active.keys.sorted() {
            do { try await finish(id, reason: stoppedByCapture ? .captureStopped : .recordingStopped) }
            catch let failure { error = error ?? failure }
        }
        if let error { throw error }
    }

    func cancel() async {
        running = false
        monitor?.cancel()
        await monitor?.value
        monitor = nil
        for track in active.values { await track.recorder.cancel() }
        active = [:]
    }

    private func finish(_ displayID: UInt32, reason: RecordingVideoTrackEndReason) async throws {
        guard var track = active.removeValue(forKey: displayID) else { return }
        let ended = clock.nowNanoseconds()
        var failure: Error?
        do { try await track.recorder.stop(at: ended) }
        catch {
            let topologyChanged = reason == .displayUnavailable || reason == .displayChanged
            if !topologyChanged || !VideoCaptureLifecycle.isUnavailableSource(error) { failure = error }
        }
        track.metadata.firstFrameTimestampNs = track.recorder.firstFrameTimestampNs
        track.metadata.endedTimestampNs = max(ended, track.metadata.firstFrameTimestampNs ?? ended)
        track.metadata.endReason = failure == nil ? reason : .failed
        finished.append(track.metadata)
        if let failure { throw failure }
    }
}
