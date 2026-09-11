import AppKit
import AVFoundation
import AVKit
import Combine
import CryptoKit
import PabloCore
import SwiftUI

extension Notification.Name {
    static let pabloAnnotationsDidChange = Notification.Name("PabloAnnotationsDidChange")
    static let pabloOpenRecordingRequested = Notification.Name("PabloOpenRecordingRequested")
}

struct RRWebObservedPlayback {
    let time: TimeInterval
    let playing: Bool
}

@MainActor
protocol RRWebPlaybackControlling: AnyObject {
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    func setPlaybackRate(_ rate: Float)
    func observedPlayback() async throws -> RRWebObservedPlayback
    func snapshot(maxPixelDimension: Int) async throws -> NSImage
}

extension RRWebPlaybackControlling {
    func snapshot(maxPixelDimension: Int) async throws -> NSImage {
        throw RecordingError.capture("The web renderer does not support image export.")
    }
}

enum ReplaySourceKind: String, Sendable {
    case native = "Screen recording"
    case web = "Safari web recording"
}

struct ReplayLibraryItem: Identifiable, Hashable, Sendable {
    let packageURL: URL
    let kind: ReplaySourceKind
    let title: String
    let detail: String
    let modifiedAt: Date

    var id: String { packageURL.standardizedFileURL.path }
}

private enum ReplaySource {
    case native(ReplayRecording)
    case web(PabloRRWebRecording, PabloRRWebReplayData)
}

@MainActor
final class ReplayModel: ObservableObject {
    let reviewID = UUID()
    private(set) var reviewSource: PabloReviewSource?
    private var loadedEvidenceDescriptor: String?
    private var pendingSeekTime: TimeInterval?
    private var seekID = UUID()
    var reviewDidChange: ((String, PabloChangeOrigin, UUID?) -> Void)?
    private var changeOrigin = PabloChangeOrigin.human
    private var changeOperationID: UUID?
    private(set) var contextRevision: UInt64 = 0 {
        didSet { reviewDidChange?("reviewChanged", changeOrigin, changeOperationID) }
    }
    @Published var hoverPoint: CGPoint? {
        didSet {
            let previous = oldValue.flatMap { videoInspection.element(at: $0) }?.id
            let current = hoverPoint.flatMap { videoInspection.element(at: $0) }?.id
            if previous != current { reviewDidChange?("hoverChanged", .human, nil) }
        }
    }
    @Published var videoTool = VideoReviewTool.inspect { didSet { if oldValue != videoTool { contextRevision += 1 } } }
    @Published var inspectorVisible = false { didSet { if oldValue != inspectorVisible { contextRevision += 1 } } }
    @Published var draftText = "" {
        didSet {
            if oldValue != draftText { contextRevision += 1 }
            if !draftText.isEmpty { captureDraftAnchor() }
        }
    }
    @Published var inspectorSection = "Elements" { didSet { if oldValue != inspectorSection { contextRevision += 1 } } }
    private var draftAnchor: PabloReviewDraftState?
    @Published var draftKind = RecordingAnnotationKind.observation { didSet { if oldValue != draftKind { contextRevision += 1 } } }
    @Published var showsCommentBox = false { didSet { if oldValue != showsCommentBox { contextRevision += 1 } } }
    @Published private(set) var rendererState = PabloReviewRendererState.empty {
        didSet { if oldValue != rendererState { reviewDidChange?("rendererChanged", .renderer, nil) } }
    }
    @Published private(set) var rendererError: String?
    @Published private(set) var renderedSeconds: TimeInterval?

    private var annotationObservation: AnyCancellable?

    init() {
        annotationObservation = NotificationCenter.default.publisher(for: .pabloAnnotationsDidChange)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let origin = (notification.userInfo?["origin"] as? String).flatMap(PabloChangeOrigin.init(rawValue:)) ?? .application
                    self.withChangeOrigin(origin, operationID: notification.userInfo?["operationID"] as? UUID) {
                        self.reloadAnnotations(changedRecordingPath: notification.object as? String)
                    }
                }
            }
    }

    private func publishAnnotations() {
        guard let packageURL else { return }
        var info: [String: Any] = ["origin": changeOrigin.rawValue]
        if let changeOperationID { info["operationID"] = changeOperationID }
        NotificationCenter.default.post(name: .pabloAnnotationsDidChange, object: packageURL.path, userInfo: info)
    }

    func reviewState() -> PabloReviewState {
        var state = PabloReviewState(reviewID: reviewID)
        state.source = reviewSource
        state.durationSeconds = duration
        state.playing = isPlaying
        state.playbackRate = Double(playbackRate)
        state.renderer = rendererState
        state.rendererError = rendererError
        state.focusedWindowID = focusedWindowID
        state.focusedWindowAvailable = focusedWindowID == nil || focusedWindowFrame != nil
        state.viewport = videoViewport
        state.tool = videoTool == .review ? "notes" : videoTool.rawValue.lowercased()
        state.inspectorVisible = inspectorVisible
        state.inspectorSection = inspectorSection.lowercased()
        state.annotationCount = annotations.count
        state.streamIssues = recording?.streamIssues ?? []
        if let recording {
            let timestamp = recording.sessionTimestampNs(forVideoTime: currentVideoTime)
            state.videoAvailability = recording.videoTracks.contains { track in
                track.metadata.contains(timestampNs: timestamp) &&
                (videoViewport.map { $0.cgRect.intersects(track.metadata.frame.cgRect) } ?? true)
            } ? .available : .unavailable
            let samples = recording.accessibilitySteps(atVideoTime: currentVideoTime)
            state.observations = samples.map { observation($0, at: timestamp) }
            state.accessibilityAvailability = samples.isEmpty ? .unavailable : .available
            if let selectedNodeID, let step = selectedStep {
                state.pinnedEvidence = evidenceSelection(step, nodeID: selectedNodeID)
            }
            if videoTool == .inspect, let hoverPoint, let hit = videoInspection.element(at: hoverPoint) {
                state.hoveredEvidence = evidenceSelection(hit.step, nodeID: hit.node.id)
            }
        } else if webRecording != nil {
            state.videoAvailability = rendererState == .ready ? .available : .unavailable
            state.accessibilityAvailability = .unsupported
        }
        state.error = errorMessage
        if let annotation = selectedAnnotation {
            state.selection = .init(kind: "annotation", reference: annotation.reference,
                                    timestampNs: annotation.startTimestampNs)
        } else if let item = selectedTimelineItem {
            state.selection = .init(kind: "event", reference: item.id, timestampNs: item.timestampNs)
        } else if let step = selectedStep {
            state.selection = .init(kind: selectedNodeID == nil ? "frame" : "node", reference: step.reference,
                                    applicationID: step.applicationID, nodeID: selectedNodeID, timestampNs: step.timestampNs)
        }
        if draftAnchor != nil || showsCommentBox || !draftText.isEmpty || !draftTraceSamples.isEmpty {
            var draft = draftAnchor ?? PabloReviewDraftState()
            draft.text = String(draftText.prefix(4_096))
            draft.characterCount = draftText.count
            draft.textTruncated = draft.characterCount > 4_096
            draft.kind = draftKind.rawValue
            draft.sampleCount = draftTraceSamples.count
            draft.startTimestampNs = draftTraceSamples.first?.timestampNs
            draft.endTimestampNs = draftTraceSamples.last?.timestampNs
            state.draft = draft
        }
        state.revision = contextRevision
        state.playheadSeconds = currentVideoTime
        state.renderedSeconds = renderedSeconds
        state.sessionTimestampNs = sessionTimestampNs(forVideoTime: currentVideoTime)
        return state
    }

    private func evidenceSelection(_ step: ReplayAccessibilityStep, nodeID: String) -> PabloReviewSelection {
        .init(kind: "node", reference: step.reference, applicationID: step.applicationID,
              nodeID: nodeID, timestampNs: step.timestampNs)
    }

    private func observation(_ step: ReplayAccessibilityStep, at timestamp: UInt64) -> PabloReviewObservation {
        .init(reference: step.reference, applicationID: step.applicationID, timestampNs: step.timestampNs,
              ageNanoseconds: timestamp >= step.timestampNs ? timestamp - step.timestampNs : 0, truncated: step.truncated)
    }

    func queryEvidence(_ request: PabloReviewEvidenceRequest) async throws -> PabloReviewEvidence {
        var result = PabloReviewEvidence(state: reviewState())
        switch request.kind {
        case .point:
            guard recording != nil else { throw RecordingError.usage("Native point inspection is unsupported for web recordings.") }
            if focusedWindowID == nil || focusedWindowFrame != nil,
               let hit = videoInspection.element(at: CGPoint(x: request.x!, y: request.y!)) {
                result.node = hit.node
                result.observation = observation(hit.step, at: result.state.sessionTimestampNs)
                result.region = .init(x: hit.region.minX, y: hit.region.minY, width: hit.region.width, height: hit.region.height)
            }
        case .timeline:
            let start = request.fromSeconds ?? 0
            let end = request.toSeconds ?? duration
            guard end <= duration else { throw RecordingError.usage("The query extends beyond this recording.") }
            let matches = timelineItems.filter {
                videoTime(forTimestampNs: $0.endTimestampNs) >= start && videoTime(forTimestampNs: $0.timestampNs) <= end
            }.sorted { $0.timestampNs == $1.timestampNs ? $0.id < $1.id : $0.timestampNs < $1.timestampNs }
            guard request.after <= matches.count else { throw RecordingError.usage("The timeline cursor is outside this query.") }
            result.items = Array(matches.dropFirst(request.after).prefix(request.limit))
            result.nextCursor = request.after + result.items.count
            result.hasMore = result.nextCursor < matches.count
        case .image:
            guard !isPlaying, rendererState == .ready, let renderedSeconds,
                  abs(renderedSeconds - currentVideoTime) <= 0.06 else {
                throw RecordingError.capture("Pause and settle the renderer before exporting a frame.")
            }
            guard result.state.videoAvailability == .available, result.state.focusedWindowAvailable else {
                throw RecordingError.capture("No recorded video is available in this viewport at this time.")
            }
            let image: CGImage
            let actualTime: Double
            if let recording, let item = player.currentItem {
                let generator = AVAssetImageGenerator(asset: item.asset)
                generator.videoComposition = item.videoComposition
                generator.maximumSize = CGSize(width: request.maxPixelDimension, height: request.maxPixelDimension)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let generated = try await generator.image(at: CMTime(seconds: renderedSeconds, preferredTimescale: 1_000_000_000))
                actualTime = generated.actualTime.seconds
                if let viewport = videoViewport, viewport != recording.captureFrame {
                    let rect = recording.captureFrame.normalizedRect(for: viewport)
                    let pixels = CGRect(x: rect.minX * Double(generated.image.width), y: rect.minY * Double(generated.image.height),
                                        width: rect.width * Double(generated.image.width), height: rect.height * Double(generated.image.height)).integral
                    guard let cropped = generated.image.cropping(to: pixels) else { throw RecordingError.capture("The recorded crop is unavailable.") }
                    image = cropped
                } else { image = generated.image }
            } else if let controller = webPlaybackController {
                let snapshot = try await controller.snapshot(maxPixelDimension: request.maxPixelDimension)
                guard let pixels = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw RecordingError.capture("The web renderer returned no image.")
                }
                image = pixels
                actualTime = renderedSeconds
            } else { throw RecordingError.capture("The renderer is unavailable.") }
            try Task.checkCancellation()
            let scale = min(1, Double(request.maxPixelDimension) / Double(max(image.width, image.height)))
            let boundedImage: CGImage
            if scale < 1 {
                guard let context = CGContext(data: nil, width: max(1, Int(Double(image.width) * scale)),
                    height: max(1, Int(Double(image.height) * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw RecordingError.capture("Could not resize the exported frame.")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                guard let resized = context.makeImage() else { throw RecordingError.capture("Could not encode the exported frame.") }
                boundedImage = resized
            } else { boundedImage = image }
            let bitmap = NSBitmapImageRep(cgImage: boundedImage)
            guard let bytes = bitmap.representation(using: .png, properties: [:]), bytes.count <= 8 * 1_024 * 1_024 else {
                throw RecordingError.capture("The image exceeds the bounded response size; request a smaller dimension.")
            }
            result.image = .init(base64: bytes.base64EncodedString(), width: boundedImage.width, height: boundedImage.height, renderedSeconds: actualTime)
        }
        return result
    }

    var draftTime: TimeInterval? { draftAnchor?.anchorTimestampNs.map(videoTime(forTimestampNs:)) }

    private func captureDraftAnchor(timestampNs: UInt64? = nil) {
        guard draftAnchor == nil, let reviewSource else { return }
        var anchor = PabloReviewDraftState()
        anchor.draftID = UUID()
        anchor.sourceGeneration = reviewSource.generation
        anchor.anchorTimestampNs = timestampNs ?? sessionTimestampNs(forVideoTime: currentVideoTime)
        anchor.accessibilityReference = selectedStep?.reference
        anchor.applicationID = selectedStep?.applicationID
        anchor.nodeID = selectedNodeID
        anchor.coordinateFrame = recording?.captureFrame
        draftAnchor = anchor
    }

    func sourceIsUnchanged() -> Bool {
        guard let packageURL, let loadedEvidenceDescriptor else { return false }
        return (try? Self.evidenceDescriptor(packageURL)) == loadedEvidenceDescriptor
    }

    private static func evidenceDescriptor(_ package: URL) throws -> String {
        func files(_ directory: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]).sorted { $0.path < $1.path }.flatMap { url -> [String] in
                if url.lastPathComponent == "annotations.pb" { return [] }
                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { return try files(url) }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return ["\(url.path)|\(attributes[.systemNumber] ?? "")|\(attributes[.systemFileNumber] ?? "")|\(attributes[.size] ?? "")|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"]
            }
        }
        return try files(package).joined(separator: "\n")
    }

    private func withChangeOrigin<T>(_ origin: PabloChangeOrigin, operationID: UUID?, _ body: () throws -> T) rethrows -> T {
        let previousOrigin = changeOrigin
        let previousOperation = changeOperationID
        changeOrigin = origin
        changeOperationID = operationID
        defer { changeOrigin = previousOrigin; changeOperationID = previousOperation }
        return try body()
    }

    func performReviewCommand(_ command: PabloReviewCommand, operationID: UUID? = nil) async throws {
        try command.validate()
        try Task.checkCancellation()
        try withChangeOrigin(.application, operationID: operationID) {
        switch command.kind {
        case .tool:
            videoTool = command.tool == "notes" ? .review : VideoReviewTool.allCases.first {
                $0.rawValue.lowercased() == command.tool
            }!
        case .showInspector: inspectorVisible = command.visible!
        case .focusWindow:
            guard command.windowID == nil || recording?.windows.contains(where: { $0.id == command.windowID }) == true else {
                throw RecordingError.usage("The recorded window does not exist in this source.")
            }
            focusWindow(command.windowID)
        case .inspectPoint:
            try inspectRecordedPoint(x: command.x!, y: command.y!)
        case .clearSelection:
            selectAnnotation(nil)
            selectNode(nil)
            selectAccessibilityStep(nil, seek: false)
        case .seek:
            guard command.seconds! <= duration else { throw RecordingError.usage("The requested time is beyond this recording.") }
            seek(to: command.seconds!)
        case .selectFrame, .selectNode:
            guard let step = recording?.accessibilitySteps.first(where: { $0.reference == command.reference }) else {
                throw RecordingError.usage("The recorded frame does not exist in this source.")
            }
            if command.kind == .selectNode, !step.nodes.contains(where: { $0.id == command.nodeID }) {
                throw RecordingError.usage("The node does not exist in the selected recorded frame.")
            }
            selectAccessibilityStep(step.id, seek: true)
            if command.kind == .selectNode { selectNode(command.nodeID) }
            inspectorVisible = true
        case .selectEvent:
            guard let item = timelineItems.first(where: { $0.id == command.reference }) else {
                throw RecordingError.usage("The recorded event does not exist in this source.")
            }
            selectTimelineItem(item)
            inspectorVisible = true
        case .selectAnnotation:
            guard let note = annotations.first(where: { $0.reference == command.reference }) else {
                throw RecordingError.usage("The note does not exist in this source.")
            }
            selectAnnotation(note.id)
            inspectorVisible = true
        case .play: setPlaying(true)
        case .pause: setPlaying(false)
        case .rate: setPlaybackRate(Float(command.rate!))
        case .activate, .close, .annotate: break
        }
        }
        let rendererCommands: [PabloReviewCommandKind] = [.seek, .selectFrame, .selectNode, .selectEvent, .selectAnnotation, .inspectPoint, .play, .pause, .rate]
        if rendererCommands.contains(command.kind) {
            try await waitForRenderer(expectedRevision: contextRevision, generation: reviewSource?.generation,
                                      playing: isPlaying, time: currentVideoTime)
        }
    }

    private func waitForRenderer(expectedRevision: UInt64, generation: UUID?, playing: Bool, time: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard reviewSource?.generation == generation, contextRevision == expectedRevision else { throw CancellationError() }
            if rendererState == .failed { throw RecordingError.capture(rendererError ?? "The renderer failed.") }
            if webRecording != nil, let controller = webPlaybackController, rendererState != .loading {
                let observed = try await controller.observedPlayback()
                guard reviewSource?.generation == generation, contextRevision == expectedRevision else { throw CancellationError() }
                updateWebPlayback(time: observed.time, playing: observed.playing)
                if pendingSeekTime == nil, observed.playing == playing,
                   playing || abs(observed.time - time) <= 0.06 {
                    return
                }
            } else if recording != nil, !videoIsLoading {
                updateCurrentVideoTime()
                let actualPlaying = player.timeControlStatus == .playing
                if rendererState == .ready, actualPlaying == playing,
                   playing || abs((renderedSeconds ?? -1) - time) <= 0.06 { return }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw RecordingError.capture("The renderer did not settle before the deadline. Read the review state before continuing.")
    }

    func closeReview() {
        videoLoadTask?.cancel()
        seekID = UUID()
        contextRevision += 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        webPlaybackController?.pause()
        webPlaybackController = nil
        isPlaying = false
    }

    @Published private var source: ReplaySource?
    @Published private(set) var libraryItems: [ReplayLibraryItem] = []
    @Published private(set) var selectedLibraryItemID: String?
    @Published private(set) var selectedStepID: Int?
    @Published private(set) var selectedNodeID: String?
    @Published var selectedAnnotationID: UUID?
    @Published private(set) var selectedTimelineItemID: String?
    @Published private(set) var timelineItems: [ReplayTimelineItem] = []
    @Published private(set) var annotations: [RecordingAnnotation] = []
    @Published var currentVideoTime: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var isPlaying = false
    @Published var draftTraceSamples: [RecordingAnnotationTraceSample] = []
    @Published private(set) var errorMessage: String?
    let player = AVPlayer()
    private weak var webPlaybackController: RRWebPlaybackControlling?
    private var videoLoadTask: Task<Void, Never>?
    private var videoLoadID = UUID()
    @Published private(set) var videoIsLoading = false
    @Published private(set) var focusedWindowID: String?

    private var inspectionKey: String?
    private var cachedInspection: ReplayVideoInspection?

    var videoInspection: ReplayVideoInspection {
        guard let recording, let viewport = videoViewport else {
            return ReplayVideoInspection(viewport: .init(x: 0, y: 0, width: 1, height: 1), steps: [], windows: [], recordedFrames: [])
        }
        let timestamp = recording.sessionTimestampNs(forVideoTime: currentVideoTime)
        let workspace = recording.workspaceSteps.last { $0.timestampNs <= timestamp }
        let steps = recording.accessibilitySteps(atVideoTime: currentVideoTime)
        let tracks = recording.videoTracks.filter { $0.metadata.contains(timestampNs: timestamp) }
        let key = "\(recording.packageURL.path)|\(workspace?.timestampNs ?? 0)|\(steps.map(\.id))|\(tracks.map(\.id))|\(viewport)"
        if key != inspectionKey || cachedInspection == nil {
            cachedInspection = ReplayVideoInspection(
                viewport: viewport, steps: steps, windows: workspace?.windows ?? [],
                recordedFrames: tracks.map(\.metadata.frame)
            )
            inspectionKey = key
        }
        return cachedInspection!
    }

    var recording: ReplayRecording? {
        guard case .native(let recording) = source else { return nil }
        return recording
    }

    var webRecording: PabloRRWebRecording? {
        guard case .web(let recording, _) = source else { return nil }
        return recording
    }

    var webReplayData: PabloRRWebReplayData? {
        guard case .web(_, let replay) = source else { return nil }
        return replay
    }

    var packageURL: URL? { recording?.packageURL ?? webRecording?.packageURL }
    var sourceKind: ReplaySourceKind? { recording == nil ? (webRecording == nil ? nil : .web) : .native }
    var duration: TimeInterval {
        if let recording {
            return max(0.001, recording.videoTime(forTimestampNs: recording.durationNs ?? 0))
        }
        return webReplayData?.duration ?? 0.001
    }
    var availableTimelineLanes: [ReplayTimelineLane] {
        let populated = Set(timelineItems.map(\.lane))
        if recording != nil { return ReplayTimelineLane.allCases.filter { $0 != .document } }
        return ReplayTimelineLane.allCases.filter { populated.contains($0) }
    }
    var selectedWebEvent: PabloRRWebReplayEvent? {
        guard case .rrweb(let index) = selectedTimelineItem?.references.first else { return nil }
        return webReplayData?.event(index: index)
    }

    var selectedStep: ReplayAccessibilityStep? {
        guard let recording, let selectedStepID else { return nil }
        return recording.accessibilitySteps.first { $0.id == selectedStepID }
    }

    var previousStep: ReplayAccessibilityStep? {
        guard let recording, let selectedStep else { return nil }
        return recording.accessibilitySteps.last {
            $0.id < selectedStep.id && $0.applicationID == selectedStep.applicationID
        }
    }

    var selectedNode: ReplayAccessibilityNode? {
        guard let selectedStep, let selectedNodeID else { return nil }
        return selectedStep.nodes.first { $0.id == selectedNodeID }
    }

    var selectedNodeChange: ReplayAccessibilityChange? {
        guard let selectedStep, let selectedNodeID else { return nil }
        return selectedStep.changes(from: previousStep).first { $0.node.id == selectedNodeID }
    }

    var currentWorkspace: WorkspaceSnapshotRecord? {
        recording?.workspaceStep(atVideoTime: currentVideoTime)
    }

    var focusedWindowFrame: RecordingRect? {
        guard let focusedWindowID else { return nil }
        return recording?.windowFrame(id: focusedWindowID, atVideoTime: currentVideoTime)
    }

    var videoViewport: RecordingRect? {
        guard let recording else { return nil }
        return focusedWindowFrame ?? recording.captureFrame
    }

    func focusWindow(_ id: String?) {
        guard id == nil || recording?.windows.contains(where: { $0.id == id }) == true else { return }
        contextRevision += 1
        focusedWindowID = id
        hoverPoint = nil
        beginTrace()
    }

    var selectedNodeVideoRegion: CGRect? {
        guard let node = selectedNode, let frame = node.frame,
              frame.width > 0, frame.height > 0, let recording else { return nil }
        let timestamp = recording.sessionTimestampNs(forVideoTime: currentVideoTime)
        let nodeBounds = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        guard recording.videoTracks.contains(where: {
            $0.metadata.contains(timestampNs: timestamp) && $0.metadata.frame.cgRect.intersects(nodeBounds)
        }) else { return nil }
        let referenceFrame = recording.captureFrame
        guard referenceFrame.width > 0, referenceFrame.height > 0 else { return nil }
        let region = CGRect(
            x: (frame.x - referenceFrame.x) / referenceFrame.width,
            y: (frame.y - referenceFrame.y) / referenceFrame.height,
            width: frame.width / referenceFrame.width,
            height: frame.height / referenceFrame.height
        )
        let clipped = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    var selectedAnnotation: RecordingAnnotation? {
        guard let selectedAnnotationID else { return nil }
        return annotations.first { $0.id == selectedAnnotationID }
    }

    var selectedTimelineItem: ReplayTimelineItem? {
        guard let selectedTimelineItemID else { return nil }
        return timelineItems.first { $0.id == selectedTimelineItemID }
    }

    func loadLatest(
        preferredURL: URL?,
        directory: URL? = nil
    ) -> Bool {
        do {
            try loadLibrary(directory: directory ?? Self.recordingsDirectory, including: preferredURL)
            guard let target = preferredURL ?? libraryItems.first?.packageURL else {
                errorMessage = "No Pablo recordings were found."
                return false
            }
            return load(target)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func selectLibraryItem(_ id: String?) {
        guard let id, let item = libraryItems.first(where: { $0.id == id }) else { return }
        _ = load(item.packageURL)
    }

    func refreshLibrary() {
        do {
            try loadLibrary(directory: Self.recordingsDirectory, including: packageURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadLibrary(directory: URL, including preferredURL: URL?) throws {
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: directory.path) {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.caseInsensitiveCompare("pablo") == .orderedSame }
        }
        if let preferredURL,
           !urls.contains(where: { $0.standardizedFileURL == preferredURL.standardizedFileURL }) {
            urls.append(preferredURL)
        }
        libraryItems = urls.compactMap { url in
            let modifiedAt = modificationDate(url)
            if let web = try? PabloRRWebRecordingStorage.load(url) {
                return ReplayLibraryItem(
                    packageURL: url,
                    kind: .web,
                    title: web.manifest.tab.title,
                    detail: "\(web.manifest.eventCount) web events",
                    modifiedAt: modifiedAt
                )
            }
            // Library discovery reads metadata; evidence is validated when the source is opened.
            guard ReplayRecording.hasNativeManifest(at: url) else { return nil }
            return ReplayLibraryItem(
                packageURL: url,
                kind: .native,
                title: url.deletingPathExtension().lastPathComponent,
                detail: "Video and accessibility evidence",
                modifiedAt: modifiedAt
            )
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func inspectRecordedPoint(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw RecordingError.usage("Recorded coordinates must be between 0 and 1.")
        }
        guard recording != nil else { throw RecordingError.usage("Native recorded points are unsupported for web recordings.") }
        guard rendererState == .ready, !isPlaying else { throw RecordingError.capture("Pause and settle the review before selecting a recorded point.") }
        guard focusedWindowID == nil || focusedWindowFrame != nil,
              let element = videoInspection.element(at: CGPoint(x: x, y: y)) else {
            throw RecordingError.usage("No accessible recorded element was observed at this point.")
        }
        pinVideoElement(element)
        inspectorVisible = true
    }

    func pinVideoElement(_ element: ReplayVideoElement) {
        seek(to: currentVideoTime, synchronizeEvidence: false)
        selectedAnnotationID = nil
        selectedTimelineItemID = nil
        selectAccessibilityStep(element.step.id, seek: false)
        selectNode(element.node.id)
    }

    func selectNode(_ id: String?) {
        contextRevision += 1
        guard id == nil || selectedStep?.nodes.contains(where: { $0.id == id }) == true else { return }
        selectedAnnotationID = nil
        selectedTimelineItemID = nil
        selectedNodeID = id
        if id != nil { inspectorSection = "Elements" }
    }

    func selectAccessibilityStep(_ id: Int?, seek: Bool) {
        selectedStepID = id
        guard let step = selectedStep else { return }
        if seek { selectedAnnotationID = nil; selectedTimelineItemID = nil; inspectorSection = "Elements" }
        if let selectedNodeID,
           !step.nodes.contains(where: { $0.id == selectedNodeID }) {
            self.selectedNodeID = nil
        }
        if seek { seekToSelectedStep() }
    }

    func seekToSelectedStep() {
        guard let recording, let step = selectedStep else { return }
        seek(to: recording.videoTime(for: step), synchronizeEvidence: false)
    }

    func seek(to seconds: TimeInterval, synchronizeEvidence: Bool = true) {
        guard seconds.isFinite else { return }
        contextRevision += 1
        if synchronizeEvidence {
            selectedAnnotationID = nil
            selectedTimelineItemID = nil
        }
        let value = min(max(0, seconds), duration)
        seekID = UUID()
        let currentSeek = seekID
        pendingSeekTime = value
        if rendererState == .ready { rendererState = .seeking }
        if webRecording != nil {
            webPlaybackController?.pause()
            webPlaybackController?.seek(to: value)
        } else {
            player.pause()
            if !videoIsLoading {
                player.seek(to: CMTime(seconds: value, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    Task { @MainActor in
                        guard let self, self.seekID == currentSeek, finished else { return }
                        self.pendingSeekTime = nil
                        self.renderedSeconds = self.player.currentTime().seconds
                        if self.player.currentItem?.status == .readyToPlay { self.rendererState = .ready }
                    }
                }
            }
        }
        isPlaying = false
        currentVideoTime = value
        if synchronizeEvidence { synchronizeTimeDependentUI(to: value) }
    }

    func togglePlayback() { setPlaying(!isPlaying) }

    func setPlaying(_ playing: Bool) {
        contextRevision += 1
        if playing && currentVideoTime >= duration - 0.01 {
            seek(to: 0)
        }
        if webRecording != nil {
            if !playing {
                webPlaybackController?.pause()
                isPlaying = false
            } else {
                webPlaybackController?.setPlaybackRate(playbackRate)
                webPlaybackController?.play()
                isPlaying = true
            }
            return
        }
        if !playing {
            player.pause()
            isPlaying = false
        } else {
            player.defaultRate = playbackRate
            player.play()
            isPlaying = true
        }
    }

    func setPlaybackRate(_ rate: Float) {
        contextRevision += 1
        playbackRate = min(max(rate, 0.5), 8)
        if webRecording != nil {
            webPlaybackController?.setPlaybackRate(playbackRate)
            return
        }
        player.defaultRate = playbackRate
        if isPlaying || player.timeControlStatus == .playing {
            player.rate = playbackRate
            isPlaying = true
        }
    }

    func updateCurrentVideoTime() {
        guard recording != nil, !videoIsLoading else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        let value = max(0, seconds)
        if renderedSeconds != value { renderedSeconds = value }
        if player.currentItem?.status == .failed {
            rendererState = .failed
            rendererError = player.currentItem?.error?.localizedDescription ?? "Video playback failed."
        } else if player.currentItem?.status == .readyToPlay, rendererState == .loading {
            rendererState = .ready
        }
        if pendingSeekTime == nil, abs(value - currentVideoTime) > 0.0005 { currentVideoTime = value }
        if isPlaying {
            if player.timeControlStatus == .playing,
               abs(player.rate - playbackRate) > 0.001 {
                player.rate = playbackRate
            }
            synchronizeTimeDependentUI(to: value)
            if player.timeControlStatus == .paused,
               let duration = player.currentItem?.duration.seconds,
               duration.isFinite,
               value >= max(0, duration - 0.01) {
                isPlaying = false
            }
        }
    }

    func beginTrace() {
        contextRevision += 1
        draftAnchor = nil
        draftText = ""
        showsCommentBox = false
        draftTraceSamples = []
        errorMessage = nil
    }

    func appendTracePoint(x: Double, y: Double) {
        guard let recording else { return }
        let videoTime = player.currentTime().seconds
        let seconds = videoTime.isFinite ? max(0, videoTime) : currentVideoTime
        let sample = RecordingAnnotationTraceSample(
            timestampNs: recording.sessionTimestampNs(forVideoTime: seconds),
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
        contextRevision += 1
        captureDraftAnchor(timestampNs: sample.timestampNs)
        draftTraceSamples.append(sample)
        currentVideoTime = seconds
    }

    func selectAnnotation(_ id: UUID?) {
        contextRevision += 1
        selectedAnnotationID = nil
        selectedTimelineItemID = nil
        selectedNodeID = nil
        guard let id, let annotation = annotations.first(where: { $0.id == id }) else { return }
        if let timestamp = annotation.startTimestampNs {
            seek(to: videoTime(forTimestampNs: timestamp))
        }
        selectedAnnotationID = id
        inspectorSection = "Notes"
        selectedTimelineItemID = "annotation:\(annotation.id.uuidString)"
        guard let recording else { return }
        if let reference = annotation.accessibilityReferences.first,
           let step = recording.accessibilitySteps.first(where: { $0.reference == reference }) {
            selectAccessibilityStep(step.id, seek: false)
        }
        selectedNodeID = annotation.accessibilityNodeIDs.first
    }

    func selectTimelineItem(_ item: ReplayTimelineItem) {
        selectedNodeID = nil
        seek(to: videoTime(forTimestampNs: item.timestampNs))
        selectedTimelineItemID = item.id
        inspectorSection = "Activity"
        guard let reference = item.references.first else { return }
        switch reference {
        case .accessibility(let id):
            selectAccessibilityStep(id, seek: false)
            inspectorSection = "Elements"
        case .annotation(let id):
            selectAnnotation(id)
        case .workspace, .input, .automation, .rrweb:
            break
        }
    }

    func moveToMeaningfulTimelineItem(_ direction: Int) {
        let currentTimestamp = sessionTimestampNs(forVideoTime: currentVideoTime)
        let items = timelineItems.filter { $0.importance >= .meaningful }
        let item = direction < 0
            ? items.last(where: { $0.timestampNs + 1_000_000 < currentTimestamp })
            : items.first(where: { $0.timestampNs > currentTimestamp + 1_000_000 })
        if let item { selectTimelineItem(item) }
    }

    func applicationName(for id: String) -> String {
        guard let recording else { return webRecording?.manifest.tab.title ?? id }
        for workspace in recording.workspaceSteps.reversed() {
            if let application = workspace.applications.first(where: { $0.id == id }) {
                return application.name
            }
        }
        return id
    }

    func addApprovedAnnotation(_ command: PabloReviewCommand, author: RecordingAnnotationAuthor, operationID: UUID? = nil) throws -> RecordingAnnotation {
        guard let packageURL, command.kind == .annotate else { throw RecordingError.usage("No recording is open for annotation.") }
        try command.validate()
        let applicationIDs: [String]
        if let reference = command.reference {
            guard let step = recording?.accessibilitySteps.first(where: { $0.reference == reference }) else {
                throw RecordingError.usage("The annotation frame does not exist in this source.")
            }
            applicationIDs = [step.applicationID]
        } else {
            applicationIDs = webRecording.map { ["SAFARI-TAB-\($0.manifest.tab.id)"] } ?? []
        }
        let annotation = try RecordingAnnotationStore.add(to: packageURL, draft: .init(
            kind: command.annotationKind ?? .observation, text: command.text!,
            startTimestampNs: command.timestampNs, endTimestampNs: command.timestampNs,
            applicationIDs: applicationIDs, accessibilityReferences: command.reference.map { [$0] } ?? [],
            accessibilityNodeIDs: command.nodeID.map { [$0] } ?? [], trace: nil), author: author)
        withChangeOrigin(.application, operationID: operationID) { publishAnnotations() }
        return annotation
    }

    @discardableResult
    func saveQuickNote(kind: RecordingAnnotationKind, attachEvidence: Bool, lineWidth: Double) -> Bool {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return addHumanAnnotation(text: text, kind: kind, attachEvidence: attachEvidence, lineWidth: lineWidth)
    }

    func addHumanAnnotation(
        text: String,
        kind: RecordingAnnotationKind,
        attachEvidence: Bool,
        lineWidth: Double
    ) -> Bool {
        guard let packageURL else { return false }
        do {
            if let generation = draftAnchor?.sourceGeneration, generation != reviewSource?.generation {
                throw RecordingError.usage("The draft belongs to a different recording source.")
            }
            if recording == nil {
                let timestamp = draftAnchor?.anchorTimestampNs ?? sessionTimestampNs(forVideoTime: currentVideoTime)
                let annotation = try RecordingAnnotationStore.add(
                    to: packageURL,
                    draft: RecordingAnnotationDraft(
                        kind: kind,
                        text: text,
                        startTimestampNs: timestamp,
                        endTimestampNs: timestamp,
                        applicationIDs: webRecording.map { ["SAFARI-TAB-\($0.manifest.tab.id)"] } ?? [],
                        accessibilityReferences: [],
                        accessibilityNodeIDs: [],
                        trace: nil
                    ),
                    author: .localHuman
                )
                publishAnnotations()
                selectAnnotation(annotation.id)
                beginTrace()
                errorMessage = nil
                return true
            }
            guard let recording else { return false }
            let selectedStep = attachEvidence ? (draftAnchor?.accessibilityReference.flatMap { reference in
                recording.accessibilitySteps.first { $0.reference == reference }
            } ?? (draftAnchor == nil ? self.selectedStep : nil)) : nil
            let anchoredNodeID = draftAnchor == nil ? selectedNodeID : draftAnchor?.nodeID
            let currentTimestamp = draftAnchor?.anchorTimestampNs ?? recording.sessionTimestampNs(forVideoTime: currentVideoTime)
            let trace = draftTraceSamples.isEmpty
                ? nil
                : RecordingAnnotationTrace(
                    samples: draftTraceSamples, lineWidth: lineWidth, coordinateFrame: recording.captureFrame
                )
            let startTimestamp = trace?.startTimestampNs ?? currentTimestamp
            let endTimestamp = trace?.endTimestampNs ?? currentTimestamp
            var applicationIDs = Set(selectedStep.map { [$0.applicationID] } ?? [])
            for sample in trace?.samples ?? [] {
                if let applicationID = recording.applicationID(
                    atNormalizedX: sample.x,
                    y: sample.y,
                    timestampNs: sample.timestampNs
                ) {
                    applicationIDs.insert(applicationID)
                }
            }
            let annotation = try RecordingAnnotationStore.add(
                to: recording.packageURL,
                draft: RecordingAnnotationDraft(
                    kind: kind,
                    text: text,
                    startTimestampNs: startTimestamp,
                    endTimestampNs: endTimestamp,
                    applicationIDs: Array(applicationIDs).sorted(),
                    accessibilityReferences: selectedStep.map { [$0.reference] } ?? [],
                    accessibilityNodeIDs: attachEvidence ? anchoredNodeID.map { [$0] } ?? [] : [],
                    trace: trace
                ),
                author: .localHuman
            )
            publishAnnotations()
            selectAnnotation(annotation.id)
            beginTrace()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func resolveSelectedAnnotation() {
        guard let packageURL, let annotation = selectedAnnotation else { return }
        do {
            let updated = try RecordingAnnotationStore.resolve(
                in: packageURL,
                reference: annotation.reference,
                author: .localHuman
            )
            publishAnnotations()
            selectedAnnotationID = updated.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadAnnotations(changedRecordingPath: String? = nil) {
        guard let packageURL else { return }
        if let changedRecordingPath,
           URL(fileURLWithPath: changedRecordingPath).standardizedFileURL !=
            packageURL.standardizedFileURL {
            return
        }
        do {
            let updated = try RecordingAnnotationStore.load(from: packageURL)
            if updated != annotations { contextRevision += 1 }
            annotations = updated
            if let recording {
                timelineItems = recording.timelineItems(annotations: annotations)
            } else if let webReplayData {
                timelineItems = webReplayData.timelineItems(annotations: annotations)
            }
            if let selectedAnnotationID,
               !annotations.contains(where: { $0.id == selectedAnnotationID }) {
                self.selectedAnnotationID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load(_ url: URL) -> Bool {
        guard reviewState().draft == nil else {
            errorMessage = "Save or discard the unsaved note before changing the recording."
            return false
        }
        do {
            // Read and validate completely before replacing the human's current review.
            let descriptor = try Self.evidenceDescriptor(url)
            let manifest = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
            let sourceID = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
            let nextSource: ReplaySource
            let nextAnnotations: [RecordingAnnotation]
            let nextTimeline: [ReplayTimelineItem]
            if let webRecording = try? PabloRRWebRecordingStorage.load(url) {
                let replayData = try PabloRRWebReplayData(recording: webRecording)
                nextSource = .web(webRecording, replayData)
                nextAnnotations = try RecordingAnnotationStore.load(from: url)
                nextTimeline = replayData.timelineItems(annotations: nextAnnotations)
            } else {
                let recording = try ReplayRecording.load(from: url)
                nextSource = .native(recording)
                nextAnnotations = recording.annotations
                nextTimeline = recording.timelineItems(annotations: nextAnnotations)
            }
            guard try Self.evidenceDescriptor(url) == descriptor else {
                throw RecordingError.capture("The recording changed while it was loading. Open it again after capture finishes.")
            }
            contextRevision += 1
            videoLoadTask?.cancel()
            videoLoadID = UUID()
            seekID = UUID()
            pendingSeekTime = nil
            videoIsLoading = false
            focusedWindowID = nil
            hoverPoint = nil
            inspectionKey = nil
            cachedInspection = nil
            rendererState = .loading
            rendererError = nil
            renderedSeconds = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            webPlaybackController?.pause()
            webPlaybackController = nil
            source = nextSource
            annotations = nextAnnotations
            timelineItems = nextTimeline
            selectedStepID = recording?.accessibilitySteps.first?.id
            loadedEvidenceDescriptor = descriptor
            reviewSource = .init(sourceID: sourceID, generation: UUID(),
                                 recordingPath: url.standardizedFileURL.path,
                                 dataSource: recording == nil ? "rrweb" : "native")
            videoTool = .inspect
            inspectorSection = recording == nil ? "Activity" : "Elements"
            draftAnchor = nil
            draftText = ""
            showsCommentBox = false
            selectedNodeID = nil
            selectedAnnotationID = nil
            selectedTimelineItemID = nil
            draftTraceSamples = []
            currentVideoTime = 0
            isPlaying = false
            errorMessage = recording?.streamIssues.isEmpty == false ? "This recording has incomplete evidence. Check its stream health before relying on missing events." : nil
            selectedLibraryItemID = url.standardizedFileURL.path
            if let recording { prepareVideo(recording) }
            seekToSelectedStep()
            return true
        } catch {
            if source == nil {
                rendererState = .failed
                rendererError = error.localizedDescription
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func prepareVideo(_ recording: ReplayRecording) {
        let loadID = videoLoadID
        videoIsLoading = true
        videoLoadTask = Task { [weak self] in
            do {
                let item = try await ReplayVideoComposition.makeItem(recording: recording)
                guard let self, self.videoLoadID == loadID, !Task.isCancelled else { return }
                self.player.replaceCurrentItem(with: item)
                while true {
                    let currentSeek = self.seekID
                    let finished = await self.player.seek(to: CMTime(seconds: self.currentVideoTime, preferredTimescale: 600),
                                                          toleranceBefore: .zero, toleranceAfter: .zero)
                    guard self.videoLoadID == loadID, !Task.isCancelled else { return }
                    if currentSeek != self.seekID { continue }
                    guard finished else { throw RecordingError.capture("The initial video seek was interrupted.") }
                    self.pendingSeekTime = nil
                    break
                }
                self.player.defaultRate = self.playbackRate
                if self.isPlaying { self.player.play() }
                self.videoIsLoading = false
                if item.status == .failed {
                    self.rendererState = .failed
                    self.rendererError = item.error?.localizedDescription ?? "Video playback failed."
                } else if item.status == .readyToPlay {
                    self.rendererState = .ready
                    self.renderedSeconds = self.player.currentTime().seconds
                }
            } catch {
                guard let self, self.videoLoadID == loadID, !Task.isCancelled else { return }
                self.videoIsLoading = false
                self.isPlaying = false
                self.errorMessage = error.localizedDescription
                self.rendererState = .failed
                self.rendererError = error.localizedDescription
            }
        }
    }

    func updateWebRenderer(ready: Bool, error: String? = nil) {
        guard webRecording != nil else { return }
        rendererError = error
        rendererState = error != nil ? .failed : ready ? (pendingSeekTime == nil ? .ready : .seeking) : .loading
    }

    func attachWebPlaybackController(_ controller: RRWebPlaybackControlling) {
        webPlaybackController = controller
        controller.setPlaybackRate(playbackRate)
        controller.seek(to: currentVideoTime)
        if isPlaying { controller.play() }
    }

    func detachWebPlaybackController(_ controller: RRWebPlaybackControlling) {
        if webPlaybackController === controller { webPlaybackController = nil }
    }

    func updateWebPlayback(time: TimeInterval, playing: Bool) {
        guard [.ready, .seeking].contains(rendererState), time.isFinite else { return }
        if renderedSeconds != time { renderedSeconds = time }
        let value = min(max(time, 0), duration)
        if let target = pendingSeekTime {
            guard abs(value - target) <= 0.06 || (playing && value >= target && value - target < 0.3) else { return }
            pendingSeekTime = nil
            rendererState = .ready
        }
        if abs(value - currentVideoTime) > 0.0005 { currentVideoTime = value }
        let observedPlaying = playing && value < max(0, duration - 0.001)
        if isPlaying != observedPlaying { isPlaying = observedPlaying }
    }

    func videoTime(forTimestampNs timestampNs: UInt64) -> TimeInterval {
        recording?.videoTime(forTimestampNs: timestampNs)
            ?? TimeInterval(timestampNs) / 1_000_000_000
    }

    func sessionTimestampNs(forVideoTime seconds: TimeInterval) -> UInt64 {
        recording?.sessionTimestampNs(forVideoTime: seconds)
            ?? UInt64(max(0, seconds) * 1_000_000_000)
    }

    func timelineClusters(
        lane: ReplayTimelineLane,
        visibleTimestampRange: ClosedRange<UInt64>,
        trackWidth: Double,
        minimumSpacing: Double = 10
    ) -> [ReplayTimelineCluster] {
        let candidates = timelineItems.filter {
            $0.lane == lane &&
                $0.endTimestampNs >= visibleTimestampRange.lowerBound &&
                $0.timestampNs <= visibleTimestampRange.upperBound
        }
        guard !candidates.isEmpty else { return [] }
        let span = max(1, visibleTimestampRange.upperBound - visibleTimestampRange.lowerBound)
        let binCount = max(1, Int(trackWidth / max(minimumSpacing, 1)))
        let grouped = Dictionary(grouping: candidates) { item -> Int in
            let visibleTimestamp = max(item.timestampNs, visibleTimestampRange.lowerBound)
            let progress = Double(visibleTimestamp - visibleTimestampRange.lowerBound) / Double(span)
            return min(binCount - 1, Int(progress * Double(binCount)))
        }
        let orderedGroups: [(key: Int, value: [ReplayTimelineItem])] = grouped.sorted {
            $0.key < $1.key
        }
        return orderedGroups.map { entry in
            let orderedItems = entry.value.sorted { lhs, rhs -> Bool in
                if lhs.timestampNs == rhs.timestampNs {
                    return lhs.id < rhs.id
                }
                return lhs.timestampNs < rhs.timestampNs
            }
            return ReplayTimelineCluster(lane: lane, items: orderedItems)
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func synchronizeTimeDependentUI(to seconds: TimeInterval) {
        let pinnedApplication = selectedNodeID == nil ? nil : selectedStep?.applicationID
        let step = pinnedApplication.flatMap { application in
            recording?.accessibilitySteps(atVideoTime: seconds).first { $0.applicationID == application }
        } ?? recording?.accessibilitySteps(atVideoTime: seconds).first {
            $0.applicationID == currentWorkspace?.frontmostApplicationID
        } ?? recording?.accessibilitySteps(atVideoTime: seconds).first
        guard step?.id != selectedStepID else { return }
        selectAccessibilityStep(step?.id, seek: false)
        if step == nil { selectedNodeID = nil }
    }

    static var recordingsDirectory: URL {
        PabloRecordingStorage.localRecordingsDirectory
    }
}

enum VideoReviewTool: String, CaseIterable, Identifiable {
    case inspect = "Inspect"
    case review = "Notes"
    case pen = "Pen"
    case comment = "Comment"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .inspect: return "viewfinder"
        case .review: return "text.bubble.fill"
        case .pen: return "pencil.tip"
        case .comment: return "text.bubble"
        }
    }

    var guidance: String {
        switch self {
        case .inspect: return "Hover to inspect · Click to pin an element"
        case .review: return "Select an existing note"
        case .pen: return "Draw directly on the video"
        case .comment: return "Place a point comment"
        }
    }
}

struct ReplayView: View {
    @ObservedObject var model: ReplayModel
    let openRecordings: @MainActor () -> Void
    @State private var traceLineWidth = 0.008
    @State private var attachEvidence = true
    @State private var libraryVisible = false
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HSplitView {
            if libraryVisible {
                RecordingBrowser(model: model, openRecordings: openRecordings)
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
            }

            Group {
                if let recording = model.recording {
                    review(recording)
                } else if let recording = model.webRecording {
                    webReview(recording)
                } else {
                    ContentUnavailableView {
                        Label("No Recording Open", systemImage: "rectangle.and.text.magnifyingglass")
                    } description: {
                        Text(model.errorMessage ?? "Choose a .pablo recording to review.")
                    } actions: {
                        Button("Open Recordings…", action: openRecordings)
                    }
                }
            }
            .frame(minWidth: 620)
        }
        .navigationTitle(
            model.packageURL?.deletingPathExtension().lastPathComponent ?? "Pablo Review"
        )
        .background(ReplayWindowMetadata(packageURL: model.packageURL))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy) { libraryVisible.toggle() }
                } label: {
                    Label("Recordings", systemImage: "sidebar.leading")
                }
                .help("Show or hide recordings")
            }
            ToolbarItemGroup {
            Button("Open Recordings…", action: openRecordings)
            Button {
                withAnimation(.snappy) { model.inspectorVisible.toggle() }
            } label: {
                Label(
                    model.inspectorVisible ? "Hide Inspector" : "Show Inspector",
                    systemImage: "sidebar.trailing"
                )
            }
            .help(model.inspectorVisible ? "Hide Inspector" : "Show Inspector")
            }
        }
        .onReceive(timer) { _ in model.updateCurrentVideoTime() }
    }

    private func webReview(_ recording: PabloRRWebRecording) -> some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1_080
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    webReviewMain(recording)
                        .frame(maxWidth: .infinity)
                    if model.inspectorVisible && !compact {
                        Divider()
                        ReviewInspector(
                            model: model,
                            lineWidth: $traceLineWidth,
                            kind: $model.draftKind,
                            attachEvidence: $attachEvidence,
                            close: { withAnimation(.snappy) { model.inspectorVisible = false } }
                        )
                        .frame(width: 410)
                    }
                }
                if model.inspectorVisible && compact {
                    ReviewInspector(
                        model: model,
                        lineWidth: $traceLineWidth,
                        kind: $model.draftKind,
                        attachEvidence: $attachEvidence,
                        close: { withAnimation(.snappy) { model.inspectorVisible = false } }
                    )
                    .frame(width: min(430, geometry.size.width * 0.82))
                    .background(.regularMaterial)
                    .overlay(alignment: .leading) { Divider() }
                    .shadow(color: .black.opacity(0.35), radius: 22, x: -8)
                }
            }
            .onAppear { if compact { model.inspectorVisible = false } }
            .onChange(of: compact) { _, isCompact in if isCompact { model.inspectorVisible = false } }
        }
    }

    private func webReviewMain(_ recording: PabloRRWebRecording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.manifest.tab.title).font(.title3.weight(.semibold))
                    Text(recording.manifest.tab.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Label("Safari", systemImage: "safari")
                Text(recording.manifest.state.rawValue.capitalized)
                Label("\(recording.manifest.eventCount) events", systemImage: "point.3.connected.trianglepath.dotted")
                if recording.manifest.inputsMasked {
                    Label("Inputs masked", systemImage: "eye.slash")
                }
                Label("\(model.annotations.count) notes", systemImage: "text.bubble")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = recording.manifest.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            RRWebPlayerWebView(recording: recording, model: model)
                .id(recording.manifest.recordingID)
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            UnifiedTimeline(model: model)
        }
        .padding(16)
        .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)
    }

    private func review(_ recording: ReplayRecording) -> some View {
        HStack(spacing: 0) {
            reviewMain(recording)
                .frame(maxWidth: .infinity)
            if model.inspectorVisible {
                Divider()
                ReviewInspector(
                    model: model,
                    lineWidth: $traceLineWidth,
                    kind: $model.draftKind,
                    attachEvidence: $attachEvidence,
                    close: { withAnimation(.snappy) { model.inspectorVisible = false } }
                )
                .frame(width: 310)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    private func reviewMain(_ recording: ReplayRecording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingHeader(recording)
            HStack {
                videoToolPicker
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    windowMenu(recording, compact: false)
                    windowMenu(recording, compact: true)
                }
            }
            // Focus cropping can extend the canvas's hit region past its visual clip.
            .zIndex(1)
            GeometryReader { stage in
                VideoMarkupCanvas(
                    recording: recording,
                    viewport: model.videoViewport ?? recording.captureFrame,
                    windowUnavailable: model.focusedWindowID != nil && model.focusedWindowFrame == nil,
                    player: model.player,
                    annotations: model.annotations,
                    selectedAnnotationID: model.selectedAnnotationID,
                    currentVideoTime: model.currentVideoTime,
                    draftSamples: model.draftTraceSamples,
                    draftLineWidth: traceLineWidth,
                    selectedNodeRegion: model.selectedNodeVideoRegion,
                    tool: model.videoTool,
                    inspection: model.videoInspection,
                    hoverPoint: $model.hoverPoint,
                    pinElement: { element in
                        model.pinVideoElement(element)
                        model.inspectorVisible = true
                    },
                    beginTrace: model.beginTrace,
                    appendPoint: model.appendTracePoint,
                    annotationKind: $model.draftKind,
                    showsCommentBox: $model.showsCommentBox,
                    draftText: $model.draftText,
                    saveComment: { text in
                        model.addHumanAnnotation(
                            text: text,
                            kind: model.draftKind,
                            attachEvidence: attachEvidence,
                            lineWidth: traceLineWidth
                        )
                    },
                    cancelTrace: model.beginTrace,
                    selectAnnotation: { id in
                        model.selectAnnotation(id)
                        model.inspectorVisible = true
                    }
                )
                .id(recording.packageURL)
                .allowsHitTesting(model.rendererState == .ready)
                .frame(maxWidth: stage.size.width, maxHeight: stage.size.height)
                .frame(width: stage.size.width, height: stage.size.height)
            }
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if model.videoIsLoading {
                    ProgressView("Preparing recording…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            HStack(spacing: 6) {
                Image(systemName: model.videoTool.systemImage)
                Text(model.videoTool.guidance)
                Spacer()
                if model.videoTool == .inspect { Text("Recorded accessibility").foregroundStyle(.tertiary) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            RecordedCoordinateControls(model: model)
            UnifiedTimeline(model: model)
        }
        .padding(20)
        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.packageURL) { _, _ in model.videoTool = .inspect }
    }

    private func windowMenu(_ recording: ReplayRecording, compact: Bool) -> some View {
        let title = recording.windows.first { $0.id == model.focusedWindowID }?.title ?? "All windows"
        return Menu {
            Button { model.focusWindow(nil) } label: {
                Label("All windows", systemImage: model.focusedWindowID == nil ? "checkmark" : "macwindow.on.rectangle")
            }
            Divider()
            ForEach(recording.windows, id: \.id) { window in
                Button { model.focusWindow(window.id) } label: {
                    Label(
                        window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Window \(window.systemWindowID)",
                        systemImage: model.focusedWindowID == window.id ? "checkmark" : "macwindow"
                    )
                }
            }
        } label: {
            if compact { Image(systemName: "macwindow.on.rectangle") }
            else { Label(title, systemImage: "macwindow.on.rectangle").lineLimit(1) }
        }
        .menuStyle(.borderlessButton)
        .frame(width: compact ? 32 : 180)
        .help("Focus a recorded window")
        .accessibilityLabel("Window: \(title)")
    }

    private var videoToolPicker: some View {
        Picker("Video tool", selection: $model.videoTool) {
            ForEach(VideoReviewTool.allCases) { tool in
                Label(tool.rawValue, systemImage: tool.systemImage)
                    .tag(tool)
                    .help(tool.guidance)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 340)
    }

    private func recordingHeader(_ recording: ReplayRecording) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.scopeName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Screen recording · \(recording.accessibilitySteps.count) accessibility snapshots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Local recording", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

}

/// Keyboard and accessibility equivalent of normalized canvas point actions.
private struct RecordedCoordinateControls: View {
    @ObservedObject var model: ReplayModel
    @State private var expanded = false
    @State private var x = "0.5"
    @State private var y = "0.5"
    @State private var message: String?

    private var point: CGPoint? {
        guard let x = Double(x), let y = Double(y), x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private var available: Bool {
        point != nil && !model.isPlaying && model.rendererState == .ready &&
            (model.focusedWindowID == nil || model.focusedWindowFrame != nil)
    }

    var body: some View {
        DisclosureGroup("Recorded point controls", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Coordinates run from 0 to 1 across the visible video, from the top left. Pause before choosing a point.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Horizontal coordinate", text: $x)
                        .accessibilityLabel("Horizontal coordinate")
                    TextField("Vertical coordinate", text: $y)
                        .accessibilityLabel("Vertical coordinate")
                    if model.videoTool == .inspect {
                        Button("Inspect point") {
                            guard let point else { return }
                            do {
                                try model.inspectRecordedPoint(x: point.x, y: point.y)
                                message = nil
                            } catch { message = error.localizedDescription }
                        }
                        .disabled(!available)
                    } else if model.videoTool == .pen || model.videoTool == .comment {
                        Button(model.videoTool == .pen ? "Add trace point" : "Place comment") {
                            guard let point, let recording = model.recording else { return }
                            let canvas = recording.captureFrame.normalizedPoint(
                                x: point.x, y: point.y, from: model.videoViewport ?? recording.captureFrame)
                            model.appendTracePoint(x: canvas.x, y: canvas.y)
                            model.showsCommentBox = model.videoTool == .comment
                            message = nil
                        }
                        .disabled(!available || !model.draftText.isEmpty || model.showsCommentBox)
                        if model.videoTool == .pen {
                            Button("Finish trace") { model.showsCommentBox = true }
                                .disabled(model.draftTraceSamples.isEmpty || model.showsCommentBox)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                if !model.draftTraceSamples.isEmpty {
                    Text(model.draftTraceSamples.count == 1 ? "1 draft point." : "\(model.draftTraceSamples.count) draft points.").font(.caption)
                }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
            .padding(.top, 6)
        }
        .font(.caption)
        .onChange(of: model.videoTool) { _, _ in message = nil }
        .onChange(of: model.packageURL) { _, _ in message = nil }
    }
}

private struct ReplayWindowMetadata: NSViewRepresentable {
    let packageURL: URL?

    func makeNSView(context: Context) -> ReplayWindowMetadataHost {
        let view = ReplayWindowMetadataHost()
        view.packageURL = packageURL
        return view
    }

    func updateNSView(_ view: ReplayWindowMetadataHost, context: Context) {
        view.packageURL = packageURL
    }
}

private final class ReplayWindowMetadataHost: NSView {
    var packageURL: URL? {
        didSet { synchronizeWindow() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeWindow()
    }

    private func synchronizeWindow() {
        window?.representedURL = packageURL
        window?.title = packageURL?.deletingPathExtension().lastPathComponent ?? "Pablo Review"
    }
}

private struct RecordingBrowser: View {
    @ObservedObject var model: ReplayModel
    let openRecordings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                Button { model.refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh recordings")
                .help("Refresh recordings")
            }
            .padding(12)
            Divider()
            List(selection: Binding(
                get: { model.selectedLibraryItemID },
                set: { model.selectLibraryItem($0) }
            )) {
                ForEach(model.libraryItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            item.title,
                            systemImage: item.kind == .web ? "safari" : "play.rectangle"
                        )
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        Text(item.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.modifiedAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .tag(item.id)
                }
            }
            Divider()
            Button("Open Recordings…", action: openRecordings)
                .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct VideoMarkupCanvas: View {
    let recording: ReplayRecording
    let viewport: RecordingRect
    let windowUnavailable: Bool
    let player: AVPlayer
    let annotations: [RecordingAnnotation]
    let selectedAnnotationID: UUID?
    let currentVideoTime: TimeInterval
    let draftSamples: [RecordingAnnotationTraceSample]
    let draftLineWidth: Double
    let selectedNodeRegion: CGRect?
    let tool: VideoReviewTool
    let inspection: ReplayVideoInspection
    @Binding var hoverPoint: CGPoint?
    let pinElement: (ReplayVideoElement) -> Void
    let beginTrace: () -> Void
    let appendPoint: (Double, Double) -> Void
    @Binding var annotationKind: RecordingAnnotationKind
    @Binding var showsCommentBox: Bool
    @Binding var draftText: String
    let saveComment: (String) -> Bool
    let cancelTrace: () -> Void
    let selectAnnotation: (UUID?) -> Void
    @State private var isInteracting = false
    @State private var annotationCandidateID: UUID?
    @State private var gestureStart: CGPoint?
    @State private var gestureTool: VideoReviewTool?

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let hovered = tool == .inspect ? hoverPoint.flatMap { inspection.element(at: $0) } : nil
                ReplayVideoSurface(player: player)
                    .frame(
                        width: geometry.size.width * recording.captureFrame.width / viewport.width,
                        height: geometry.size.height * recording.captureFrame.height / viewport.height
                    )
                    .offset(
                        x: -geometry.size.width * (viewport.x - recording.captureFrame.x) / viewport.width,
                        y: -geometry.size.height * (viewport.y - recording.captureFrame.y) / viewport.height
                    )
                    .accessibilityHidden(true)
                TraceOverlay(
                    recording: recording,
                    viewport: viewport,
                    annotations: annotations,
                    selectedAnnotationID: selectedAnnotationID,
                    currentVideoTime: currentVideoTime,
                    draftSamples: draftSamples,
                    draftLineWidth: draftLineWidth
                )
                if let selectedNodeRegion {
                    AccessibilityBoundsOverlay(
                        region: viewport.normalizedRect(for: RecordingRect(
                            x: recording.captureFrame.x + selectedNodeRegion.minX * recording.captureFrame.width,
                            y: recording.captureFrame.y + selectedNodeRegion.minY * recording.captureFrame.height,
                            width: selectedNodeRegion.width * recording.captureFrame.width,
                            height: selectedNodeRegion.height * recording.captureFrame.height
                        )),
                        label: nil,
                        size: geometry.size
                    )
                }
                if let hovered {
                    AccessibilityBoundsOverlay(region: hovered.region, label: nil, size: geometry.size)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                            hoverPoint = CGPoint(x: point.x / geometry.size.width, y: point.y / geometry.size.height)
                        case .ended: hoverPoint = nil
                        }
                    }
                    .gesture(videoGesture(size: geometry.size))
                    .onChange(of: geometry.size) { _, _ in hoverPoint = nil }
                    .onChange(of: viewport) { _, _ in hoverPoint = nil }
                    .accessibilityLabel("Recorded video. Hover to inspect an element; click to pin it.")
                if let hovered, let hoverPoint {
                    VideoElementPopover(
                        element: hovered,
                        age: max(0, currentVideoTime - recording.videoTime(for: hovered.step))
                    )
                    .frame(width: min(260, geometry.size.width - 24))
                    .position(
                        x: min(max(hoverPoint.x * geometry.size.width + (hoverPoint.x > 0.5 ? -148 : 148), 142), geometry.size.width - 142),
                        y: hoverPoint.y * geometry.size.height > geometry.size.height / 2
                            ? max(76, hoverPoint.y * geometry.size.height - 90)
                            : min(geometry.size.height - 76, hoverPoint.y * geometry.size.height + 90)
                    )
                    .allowsHitTesting(false)
                }
                if showsCommentBox, let endpoint = draftSamples.last {
                    DraftCommentBubble(
                        kind: $annotationKind,
                        text: $draftText,
                        onSave: { text in
                            if saveComment(text) { showsCommentBox = false }
                        },
                        onCancel: {
                            showsCommentBox = false
                            cancelTrace()
                        }
                    )
                    .frame(width: 270)
                    .position(commentPosition(for: endpoint, in: geometry.size))
                }
            }
            .clipped()
            .opacity(windowUnavailable ? 0 : 1)
            .allowsHitTesting(!windowUnavailable)
            if windowUnavailable {
                ContentUnavailableView(
                    "Window unavailable",
                    systemImage: "macwindow",
                    description: Text("This window has no recorded view at the current time. Choose All windows or move along the timeline.")
                )
            }
        }
        .aspectRatio(viewport.width / max(1, viewport.height), contentMode: .fit)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onExitCommand {
            showsCommentBox = false
            hoverPoint = nil
            cancelTrace()
        }
        .onChange(of: tool) { _, _ in
            isInteracting = false
            gestureTool = nil
            gestureStart = nil
            annotationCandidateID = nil
            if showsCommentBox || !draftSamples.isEmpty {
                showsCommentBox = false
                cancelTrace()
            }
        }
    }

    private func videoGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                if !isInteracting {
                    if showsCommentBox { cancelTrace() }
                    showsCommentBox = false
                    isInteracting = true
                    gestureStart = value.location
                    gestureTool = tool
                    switch tool {
                    case .inspect: break
                    case .review:
                        annotationCandidateID = hitTestAnnotation(at: value.location, in: size)
                    case .pen:
                        beginTrace()
                    case .comment:
                        annotationCandidateID = nil
                    }
                }
                guard gestureTool == .pen else { return }
                appendPoint(at: value.location, in: size)
            }
            .onEnded { value in
                let completedTool = gestureTool ?? tool
                isInteracting = false
                switch completedTool {
                case .inspect:
                    if let start = gestureStart,
                       hypot(value.location.x - start.x, value.location.y - start.y) <= 5,
                       let element = inspection.element(at: CGPoint(
                        x: value.location.x / size.width, y: value.location.y / size.height
                       )) {
                        hoverPoint = nil
                        pinElement(element)
                    }
                case .review:
                    if let gestureStart,
                       hypot(value.location.x - gestureStart.x, value.location.y - gestureStart.y) <= 5,
                       let annotationCandidateID {
                        selectAnnotation(annotationCandidateID)
                    }
                case .pen:
                    showsCommentBox = true
                case .comment:
                    beginTrace()
                    appendPoint(at: value.location, in: size)
                    showsCommentBox = true
                }
                annotationCandidateID = nil
                gestureStart = nil
                gestureTool = nil
            }
    }

    private func appendPoint(at point: CGPoint, in size: CGSize) {
        let canvasPoint = recording.captureFrame.normalizedPoint(
            x: min(max(point.x / size.width, 0), 1),
            y: min(max(point.y / size.height, 0), 1),
            from: viewport
        )
        appendPoint(
            min(max(canvasPoint.x, 0), 1), min(max(canvasPoint.y, 0), 1)
        )
    }

    private func hitTestAnnotation(at point: CGPoint, in size: CGSize) -> UUID? {
        let timestamp = recording.sessionTimestampNs(forVideoTime: currentVideoTime)
        let frameTolerance = UInt64(500_000_000 / max(recording.framesPerSecond, 1))
        let threshold: CGFloat = 12
        return annotations.reversed().first { annotation in
            guard let trace = annotation.trace else { return false }
            let samples = trace.visibleSamples(
                at: timestamp,
                pointToleranceNs: frameTolerance,
                tailDurationNs: frameTolerance
            )
            let points = trace.samples(samples, in: viewport).map { CGPoint(x: size.width * $0.x, y: size.height * $0.y) }
            if points.contains(where: { hypot($0.x - point.x, $0.y - point.y) <= threshold }) {
                return true
            }
            return zip(points, points.dropFirst()).contains { start, end in
                distance(from: point, toSegmentFrom: start, to: end) <= threshold
            }
        }?.id
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let progress = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (start.x + progress * dx), point.y - (start.y + progress * dy))
    }

    private func commentPosition(
        for endpoint: RecordingAnnotationTraceSample,
        in size: CGSize
    ) -> CGPoint {
        let normalized = viewport.normalizedPoint(x: endpoint.x, y: endpoint.y, from: recording.captureFrame)
        let point = CGPoint(x: size.width * normalized.x, y: size.height * normalized.y)
        let halfWidth: CGFloat = 135
        let proposedX = normalized.x > 0.62
            ? point.x - halfWidth - 16
            : point.x + halfWidth + 16
        return CGPoint(
            x: min(max(proposedX, halfWidth + 8), size.width - halfWidth - 8),
            y: min(max(point.y, 58), size.height - 58)
        )
    }
}

private struct VideoElementPopover: View {
    let element: ReplayVideoElement
    let age: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "viewfinder").foregroundStyle(Color.accentColor)
                Text((element.node.role ?? "Element").replacingOccurrences(of: "AX", with: ""))
                    .fontWeight(.medium)
                Spacer()
                Text(element.step.applicationName).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .font(.caption)
            Text(accessibilityNodeName(element.node))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            if let value = element.node.value, !value.isEmpty, value != accessibilityNodeName(element.node) {
                Text(value).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            }
            HStack {
                Text(String(format: "Observed %.1fs ago", age))
                Spacer()
                Text("Click to pin")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(Color(red: 0.12, green: 0.14, blue: 0.16), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }
}

private struct AccessibilityBoundsOverlay: View {
    let region: CGRect
    let label: String?
    let size: CGSize

    var body: some View {
        let frame = CGRect(
            x: size.width * region.minX,
            y: size.height * region.minY,
            width: size.width * region.width,
            height: size.height * region.height
        )
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.04))
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.accentColor, lineWidth: 1.5)
            if let label, !label.isEmpty {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(Color.blue, in: Capsule())
                    .offset(y: -24)
            }
        }
        .frame(width: max(frame.width, 4), height: max(frame.height, 4))
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DraftCommentBubble: View {
    @Binding var kind: RecordingAnnotationKind
    @Binding var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Add a comment…", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(save)
            HStack {
                Picker("Kind", selection: $kind) {
                    ForEach(RecordingAnnotationKind.allCases, id: \.self) { value in
                        Text(value.rawValue.capitalized).tag(value)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Button("Add", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 7)
        .onAppear { isFocused = true }
    }

    private func save() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSave(value)
    }
}

private struct TraceOverlay: View {
    let recording: ReplayRecording
    let viewport: RecordingRect
    let annotations: [RecordingAnnotation]
    let selectedAnnotationID: UUID?
    let currentVideoTime: TimeInterval
    let draftSamples: [RecordingAnnotationTraceSample]
    let draftLineWidth: Double

    var body: some View {
        Canvas { context, size in
            let timestamp = recording.sessionTimestampNs(forVideoTime: currentVideoTime)
            for annotation in annotations {
                guard let trace = annotation.trace else { continue }
                let frameTolerance = UInt64(
                    500_000_000 / max(recording.framesPerSecond, 1)
                )
                let samples = trace.visibleSamples(
                    at: timestamp,
                    pointToleranceNs: frameTolerance,
                    tailDurationNs: frameTolerance
                )
                draw(
                    trace.samples(samples, in: viewport),
                    lineWidth: trace.lineWidth(in: viewport),
                    color: annotationColor(annotation.kind),
                    emphasized: annotation.id == selectedAnnotationID,
                    in: &context,
                    size: size
                )
            }
            let draft = RecordingAnnotationTrace(
                samples: draftSamples, lineWidth: draftLineWidth, coordinateFrame: recording.captureFrame
            )
            draw(
                draft.samples(draftSamples, in: viewport),
                lineWidth: draft.lineWidth(in: viewport),
                color: .yellow,
                emphasized: true,
                in: &context,
                size: size
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(
        _ samples: [RecordingAnnotationTraceSample],
        lineWidth: Double,
        color: Color,
        emphasized: Bool,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let first = samples.first else { return }
        let width = max(2, min(size.width, size.height) * lineWidth)
        if samples.count == 1 {
            let center = point(first, in: size)
            let rect = CGRect(
                x: center.x - width,
                y: center.y - width,
                width: width * 2,
                height: width * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(color))
            return
        }
        var path = Path()
        path.move(to: point(first, in: size))
        for sample in samples.dropFirst() { path.addLine(to: point(sample, in: size)) }
        context.stroke(
            path,
            with: .color(color.opacity(emphasized ? 0.32 : 0.2)),
            style: StrokeStyle(lineWidth: width * 3, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(color.opacity(emphasized ? 1 : 0.82)),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        )
    }

    private func point(_ sample: RecordingAnnotationTraceSample, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * sample.x, y: size.height * sample.y)
    }

}

private struct UnifiedTimeline: View {
    @ObservedObject var model: ReplayModel
    @State private var zoom = 1.0
    @State private var viewportCenter: TimeInterval?
    @State private var followsPlayhead = true
    @State private var showsEvidence = false

    private var duration: TimeInterval {
        model.duration
    }

    private var visibleRange: ClosedRange<TimeInterval> {
        let visibleDuration = duration / max(zoom, 1)
        let center = followsPlayhead ? model.currentVideoTime : (viewportCenter ?? model.currentVideoTime)
        let proposedStart = center - visibleDuration / 2
        let start = min(max(proposedStart, 0), max(duration - visibleDuration, 0))
        return start...(start + visibleDuration)
    }

    var body: some View {
        VStack(spacing: 7) {
                Slider(value: Binding(
                    get: { model.currentVideoTime },
                    set: { model.seek(to: $0) }
                ), in: 0...duration)
                .accessibilityLabel("Playback position")
            HStack(spacing: 14) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .help("Play or pause recording (Space)")
                .keyboardShortcut(.space, modifiers: [])
                Button { model.moveToMeaningfulTimelineItem(-1) } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous meaningful event")
                .help("Previous meaningful event")
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button { model.moveToMeaningfulTimelineItem(1) } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next meaningful event")
                .help("Next meaningful event")
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Text(formatTime(model.currentVideoTime))
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                Text("/ " + formatTime(duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Playback speed", selection: Binding(
                    get: { model.playbackRate }, set: { model.setPlaybackRate($0) }
                )) {
                    ForEach(playbackRates, id: \.self) { rate in Text(formatPlaybackRate(rate)).tag(rate) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            HStack {
                Button {
                    withAnimation(.snappy) { showsEvidence.toggle() }
                } label: {
                    Label("Event timeline", systemImage: showsEvidence ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(model.timelineItems.count) events")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
            if showsEvidence {
            HStack(spacing: 10) {
                Spacer()
                Button { panViewport(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(zoom == 1)
                .accessibilityLabel("Pan timeline backward without seeking")
                .help("Pan timeline backward without seeking")
                Button {
                    followsPlayhead = true
                    viewportCenter = model.currentVideoTime
                } label: {
                    Image(systemName: followsPlayhead ? "scope" : "dot.scope")
                }
                .buttonStyle(.borderless)
                .disabled(zoom == 1 && followsPlayhead)
                .accessibilityLabel("Follow playhead")
                .help("Follow playhead")
                Button { panViewport(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(zoom == 1)
                .accessibilityLabel("Pan timeline forward without seeking")
                .help("Pan timeline forward without seeking")
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...12)
                    .frame(width: 80)
                    .accessibilityLabel("Timeline zoom")
                    .help("Timeline zoom")
                Text(zoom == 1 ? "Fit" : String(format: "%.1f×", zoom))
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                Button {
                    zoom = 1
                    followsPlayhead = true
                    viewportCenter = model.currentVideoTime
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .disabled(zoom == 1)
                .accessibilityLabel("Fit entire recording")
                .help("Fit entire recording")
            }
            TimelineRuler(
                range: visibleRange,
                currentTime: model.currentVideoTime,
                seek: {
                    model.seek(to: $0)
                    viewportCenter = $0
                    followsPlayhead = true
                }
            )
            VStack(spacing: 3) {
                ForEach(model.availableTimelineLanes, id: \.self) { lane in
                    TimelineLaneRow(
                        lane: lane,
                        model: model,
                        visibleRange: visibleRange
                    )
                }
            }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unified recording timeline")
        .onChange(of: zoom) { _, newValue in
            viewportCenter = model.currentVideoTime
            if newValue == 1 { followsPlayhead = true }
        }
    }

    private func panViewport(_ direction: Double) {
        guard zoom > 1 else { return }
        let span = visibleRange.upperBound - visibleRange.lowerBound
        let currentCenter = (visibleRange.lowerBound + visibleRange.upperBound) / 2
        viewportCenter = min(max(currentCenter + direction * span * 0.7, span / 2), duration - span / 2)
        followsPlayhead = false
    }
}

private struct TimelineRuler: View {
    let range: ClosedRange<TimeInterval>
    let currentTime: TimeInterval
    let seek: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("TIME")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
                    HStack {
                        Text(formatTime(range.lowerBound))
                        Spacer()
                        Text(formatTime(range.upperBound))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .position(x: x(for: currentTime, width: geometry.size.width), y: 8)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                    seek(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
                })
            }
        }
        .frame(height: 16)
    }

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        let duration = max(range.upperBound - range.lowerBound, 0.001)
        return CGFloat(min(max((time - range.lowerBound) / duration, 0), 1)) * width
    }
}

private struct TimelineLaneRow: View {
    let lane: ReplayTimelineLane
    @ObservedObject var model: ReplayModel
    let visibleRange: ClosedRange<TimeInterval>
    @State private var expandedClusterID: String?

    var body: some View {
        HStack(spacing: 8) {
            Label(laneTitle, systemImage: laneIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(laneColor)
                .frame(width: 78, alignment: .leading)
            GeometryReader { geometry in
                let clusters = timelineClusters(width: geometry.size.width)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(laneColor.opacity(0.055))
                    ForEach(clusters) { cluster in
                        let markerColor = color(for: cluster)
                        TimelineMarkerPlacement(
                            centerX: x(
                                forTimestamp: cluster.timestampNs,
                                width: geometry.size.width
                            )
                        ) {
                            Button {
                                if cluster.items.count == 1, let item = cluster.items.first {
                                    model.selectTimelineItem(item)
                                } else {
                                    expandedClusterID = cluster.id
                                }
                            } label: {
                                TimelineMarker(
                                    count: cluster.memberCount,
                                    color: markerColor,
                                    warning: cluster.importance == .warning,
                                    muted: clusterIsResolved(cluster),
                                    selected: cluster.items.contains(where: {
                                        $0.id == model.selectedTimelineItemID
                                    })
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(clusterHelp(cluster))
                            .accessibilityValue(cluster.items.contains(where: {
                                $0.id == model.selectedTimelineItemID
                            }) ? "Selected" : "Not selected")
                            .help(clusterHelp(cluster))
                            .popover(isPresented: Binding(
                                get: { expandedClusterID == cluster.id },
                                set: { if !$0 { expandedClusterID = nil } }
                            )) {
                                TimelineClusterPopover(cluster: cluster, model: model)
                            }
                        }
                    }
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 20)
                        .position(x: x(forTime: model.currentVideoTime, width: geometry.size.width), y: 10)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(laneTitle) timeline lane")
    }

    private func timelineClusters(width: CGFloat) -> [ReplayTimelineCluster] {
        model.timelineClusters(
            lane: lane,
            visibleTimestampRange: model.sessionTimestampNs(forVideoTime: visibleRange.lowerBound)...model.sessionTimestampNs(forVideoTime: visibleRange.upperBound),
            trackWidth: width
        )
    }

    private func x(forTimestamp timestamp: UInt64, width: CGFloat) -> CGFloat {
        x(forTime: model.videoTime(forTimestampNs: timestamp), width: width)
    }

    private func x(forTime time: TimeInterval, width: CGFloat) -> CGFloat {
        let duration = max(visibleRange.upperBound - visibleRange.lowerBound, 0.001)
        return CGFloat(min(max((time - visibleRange.lowerBound) / duration, 0), 1)) * max(width - 8, 1) + 4
    }

    private func clusterHelp(_ cluster: ReplayTimelineCluster) -> String {
        if cluster.items.count == 1, let item = cluster.items.first {
            return "\(item.title) · \(formatTime(model.videoTime(forTimestampNs: item.timestampNs)))"
        }
        return "\(cluster.memberCount) \(laneTitle.lowercased()) events — click to inspect"
    }

    private func color(for cluster: ReplayTimelineCluster) -> Color {
        guard lane == .workspace || lane == .accessibility else { return laneColor }
        let applicationIDs = Set(cluster.items.flatMap(\.applicationIDs))
        guard applicationIDs.count == 1, let applicationID = applicationIDs.first else {
            return laneColor
        }
        return timelineApplicationColor(applicationID)
    }

    private func clusterIsResolved(_ cluster: ReplayTimelineCluster) -> Bool {
        let annotationIDs = cluster.items.flatMap(\.references).compactMap { reference -> UUID? in
            guard case .annotation(let id) = reference else { return nil }
            return id
        }
        guard !annotationIDs.isEmpty else { return false }
        return annotationIDs.allSatisfy { id in
            model.annotations.first(where: { $0.id == id })?.status == .resolved
        }
    }

    private var laneTitle: String {
        switch lane {
        case .workspace: return "APPS"
        case .input: return "INPUT"
        case .automation: return "AGENTS"
        case .accessibility: return "A11Y"
        case .document: return "DOM"
        case .annotation: return "NOTES"
        }
    }

    private var laneIcon: String {
        switch lane {
        case .workspace: return "macwindow.on.rectangle"
        case .input: return "cursorarrow.click"
        case .automation: return "cpu"
        case .accessibility: return "accessibility"
        case .document: return "doc.text.magnifyingglass"
        case .annotation: return "text.bubble"
        }
    }

    private var laneColor: Color {
        switch lane {
        case .workspace: return .teal
        case .input: return .secondary
        case .automation: return .purple
        case .accessibility: return .blue
        case .document: return .mint
        case .annotation: return .orange
        }
    }
}

private struct TimelineMarkerPlacement: Layout {
    let centerX: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let markerSize = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(
            width: proposal.width ?? markerSize.width,
            height: proposal.height ?? max(markerSize.height, 20)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let marker = subviews.first else { return }
        marker.place(
            at: CGPoint(
                x: bounds.minX + min(max(centerX, 0), bounds.width),
                y: bounds.midY
            ),
            anchor: .center,
            proposal: .unspecified
        )
    }
}

private struct TimelineMarker: View {
    let count: Int
    let color: Color
    let warning: Bool
    let muted: Bool
    let selected: Bool

    var body: some View {
        ZStack {
            Capsule()
                .fill(color.opacity(muted ? 0.28 : (selected ? 1 : 0.78)))
                .frame(width: count > 1 ? 22 : 7, height: selected ? 15 : 11)
                .overlay {
                    if warning {
                        Capsule().stroke(Color.red, lineWidth: selected ? 2 : 1.4)
                    }
                }
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct TimelineClusterPopover: View {
    let cluster: ReplayTimelineCluster
    @ObservedObject var model: ReplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(cluster.memberCount) events")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cluster.items) { item in
                        Button {
                            model.selectTimelineItem(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(2)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280, height: min(CGFloat(cluster.items.count * 52 + 50), 360))
    }
}

private struct ReviewInspector: View {
    @ObservedObject var model: ReplayModel
    @Binding var lineWidth: Double
    @Binding var kind: RecordingAnnotationKind
    @Binding var attachEvidence: Bool
    let close: () -> Void
    @State private var evidenceMode = InspectorEvidenceMode.tree
    @State private var showsEvidenceDetails = false

    private enum InspectorEvidenceMode: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case tree = "Tree"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "sidebar.trailing") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Hide Inspector")
                    .help("Hide Inspector")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Picker("Inspector section", selection: $model.inspectorSection) {
                if model.recording != nil { Text("Elements").tag("Elements") }
                Text("Activity").tag("Activity")
                Text("Notes").tag("Notes")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.inspectorSection == "Notes" {
                        HStack {
                            TextField("Write a note…", text: $model.draftText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addQuickNote)
                            Button("Add", action: addQuickNote)
                                .buttonStyle(.borderedProminent)
                                .disabled(model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if let time = model.draftTime {
                            HStack {
                                Text("Unsaved note at \(String(format: "%.2f", time)) s")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Discard", action: model.beginTrace).buttonStyle(.borderless)
                            }
                        }
                        annotationSection
                    }
                    if model.inspectorSection == "Activity" {
                        if let item = model.selectedTimelineItem {
                            SelectedTimelineContext(item: item, model: model)
                        } else {
                            Text("Select an event in the timeline to inspect what happened.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let event = model.selectedWebEvent { WebEventDetail(event: event) }
                    }
                    if model.inspectorSection == "Elements" {
                        if let node = model.selectedNode {
                            HStack {
                                Label("Pinned element", systemImage: "pin.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear") { model.selectNode(nil) }.buttonStyle(.borderless)
                            }
                            AccessibilityNodeDetail(node: node)
                                .padding(12)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: "viewfinder").font(.title2).foregroundStyle(Color.accentColor)
                                Text("Explore the recording").font(.headline)
                                Text("Hover over the video to reveal an element. Click to keep its details here.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.padding(.vertical, 12)
                        }
                        if let recording = model.recording, let step = model.selectedStep {
                            Divider()
                            EvidenceFrameHeader(recording: recording, step: step, model: model)
                                .padding(.horizontal, -12)
                            DisclosureGroup("Accessibility evidence", isExpanded: $showsEvidenceDetails) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Picker("Evidence view", selection: $evidenceMode) {
                                        ForEach(InspectorEvidenceMode.allCases) { value in
                                            Text(value.rawValue).tag(value)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()

                                    switch evidenceMode {
                                    case .changes:
                                        AccessibilityChangesView(
                                            step: step,
                                            previousStep: model.previousStep,
                                            selectedNodeID: Binding(get: { model.selectedNodeID }, set: model.selectNode)
                                        )
                                        .frame(minHeight: 170, maxHeight: 300)
                                    case .tree:
                                        AccessibilityTreeView(
                                            step: step,
                                            selectedNodeID: Binding(get: { model.selectedNodeID }, set: model.selectNode)
                                        )
                                        .frame(minHeight: 220, maxHeight: 360)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(12)
            }
        }

    }

    private func addQuickNote() {
        model.saveQuickNote(kind: kind, attachEvidence: attachEvidence, lineWidth: lineWidth)
    }

    @ViewBuilder
    private var annotationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Annotations").font(.headline)
                Spacer()
                Text("\(model.annotations.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.annotations.isEmpty {
                Text(model.webRecording == nil
                     ? "Choose Comment or Pen above the video to add a spatial note."
                     : "Add a note at the current web replay time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.annotations) { annotation in
                    Button { model.selectAnnotation(annotation.id) } label: {
                        AnnotationRow(annotation: annotation)
                            .padding(8)
                            .background(
                                model.selectedAnnotationID == annotation.id
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(model.selectedAnnotationID == annotation.id ? "Selected" : "Not selected")
                }
            }
            if let annotation = model.selectedAnnotation {
                AnnotationDetail(annotation: annotation, model: model)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct WebEventDetail: View {
    let event: PabloRRWebReplayEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("rrweb event \(event.index + 1)").font(.headline)
                Spacer()
                Text(formatTime(TimeInterval(event.timestampNs) / 1_000_000_000))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(event.formattedJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SelectedTimelineContext: View {
    let item: ReplayTimelineItem
    @ObservedObject var model: ReplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(laneName, systemImage: laneIcon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(laneColor)
                Spacer()
                Text(formatTime(model.videoTime(forTimestampNs: item.timestampNs)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(item.title).font(.subheadline.weight(.semibold))
            if let subtitle = item.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if item.memberCount > 1 {
                Text("\(item.memberCount) raw evidence records")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if !item.applicationIDs.isEmpty {
                Text(item.applicationIDs.map(model.applicationName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.lane == .accessibility || item.lane == .annotation,
               let step = model.selectedStep {
                HStack {
                    Text(step.reference).font(.caption.monospaced().weight(.bold))
                    Text(step.applicationName).font(.caption)
                    if let node = model.selectedNode {
                        Text("› \(accessibilityNodeName(node))").font(.caption).lineLimit(1)
                    }
                }
                .foregroundStyle(.blue)
                if let change = model.selectedNodeChange {
                    Text(accessibilityChangeHeadline(change))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(10)
        .background(laneColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var laneName: String { item.lane.rawValue.capitalized }
    private var laneIcon: String {
        switch item.lane {
        case .workspace: return "macwindow.on.rectangle"
        case .input: return "cursorarrow.click"
        case .automation: return "cpu"
        case .accessibility: return "accessibility"
        case .document: return "doc.text.magnifyingglass"
        case .annotation: return "text.bubble"
        }
    }
    private var laneColor: Color {
        switch item.lane {
        case .workspace: return .teal
        case .input: return .secondary
        case .automation: return .purple
        case .accessibility: return .blue
        case .document: return .mint
        case .annotation: return .orange
        }
    }
}

private struct AnnotationRow: View {
    let annotation: RecordingAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(annotation.reference)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(annotationColor(annotation.kind))
                Text(annotation.kind.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                Spacer()
                if annotation.status == .resolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                }
            }
            Text(annotation.text).font(.subheadline).lineLimit(3)
            HStack {
                Text(annotation.createdBy.displayName)
                if let frame = annotation.accessibilityReferences.first { Text(frame) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct AnnotationDetail: View {
    let annotation: RecordingAnnotation
    @ObservedObject var model: ReplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(annotation.text).textSelection(.enabled)
            HStack {
                Text("By \(annotation.createdBy.displayName)")
                Spacer()
                if annotation.status == .open {
                    Button("Resolve") { model.resolveSelectedAnnotation() }
                        .buttonStyle(.bordered)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(annotation.reference, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(annotation.reference)")
                .help("Copy \(annotation.reference)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct EvidenceFrameHeader: View {
    let recording: ReplayRecording
    let step: ReplayAccessibilityStep
    @ObservedObject var model: ReplayModel
    @State private var showsFrameJump = false
    @State private var frameReference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous accessibility frame")
                    .disabled(step.id == 0)
                    .buttonStyle(.borderless)
                Text(step.reference)
                    .font(.caption.monospaced().weight(.bold))
                    .textSelection(.enabled)
                Text("\(step.id + 1) of \(recording.accessibilitySteps.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next accessibility frame")
                    .disabled(step.id + 1 >= recording.accessibilitySteps.count)
                    .buttonStyle(.borderless)
                Button {
                    frameReference = step.reference
                    showsFrameJump = true
                } label: {
                    Image(systemName: "number")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Go to accessibility frame")
                .help("Go to accessibility frame")
                .popover(isPresented: $showsFrameJump) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Go to accessibility frame").font(.headline)
                        TextField("A11Y-012", text: $frameReference)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(jumpToFrame)
                        Button("Go", action: jumpToFrame)
                            .buttonStyle(.borderedProminent)
                            .disabled(frameID(from: frameReference) == nil)
                    }
                    .padding(12)
                    .frame(width: 230)
                }
                Spacer()
                Text(model.previousStep == nil
                     ? "Baseline"
                     : "\(step.changes(from: model.previousStep).count) raw changes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            let playheadTimestamp = recording.sessionTimestampNs(forVideoTime: model.currentVideoTime)
            if step.timestampNs <= playheadTimestamp {
                Text("Observed \(formatTime(Double(playheadTimestamp - step.timestampNs) / 1_000_000_000)) before playhead")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This observation is after the current playhead")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(step.reason.replacingOccurrences(of: "input:", with: ""))
                .font(.subheadline)
                .lineLimit(2)
            Label(step.applicationName, systemImage: "app")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
            HStack(spacing: 10) {
                Label("\(step.totalNodeCount) nodes", systemImage: "point.3.connected.trianglepath.dotted")
                if !step.removedNodeIDs.isEmpty {
                    Label("\(step.removedNodeIDs.count) removed", systemImage: "minus.circle")
                }
                if step.truncated { Label("Truncated", systemImage: "exclamationmark.triangle") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func move(by offset: Int) {
        let id = step.id + offset
        guard recording.accessibilitySteps.indices.contains(id) else { return }
        model.selectAccessibilityStep(id, seek: true)
    }

    private func jumpToFrame() {
        guard let id = frameID(from: frameReference),
              recording.accessibilitySteps.contains(where: { $0.id == id }) else { return }
        model.selectAccessibilityStep(id, seek: true)
        showsFrameJump = false
    }

    private func frameID(from reference: String) -> Int? {
        let digits = reference.filter(\.isNumber)
        guard let oneBased = Int(digits), oneBased > 0 else { return nil }
        return oneBased - 1
    }
}

private struct AccessibilityChangesView: View {
    let step: ReplayAccessibilityStep
    let previousStep: ReplayAccessibilityStep?
    @Binding var selectedNodeID: String?
    @State private var showsTechnicalChanges = false

    private var changes: [ReplayAccessibilityChange] {
        step.changes(from: previousStep).sorted { lhs, rhs in
            changePriority(lhs) < changePriority(rhs)
        }
    }

    private var semanticChanges: [ReplayAccessibilityChange] {
        changes.filter(replayAccessibilityChangeIsSemantic)
    }

    private var technicalChanges: [ReplayAccessibilityChange] {
        changes.filter { !replayAccessibilityChangeIsSemantic($0) }
    }

    var body: some View {
        if previousStep == nil {
            AccessibilityBaselineSummary(step: step)
        } else if changes.isEmpty {
            ContentUnavailableView(
                "No semantic changes",
                systemImage: "equal.circle",
                description: Text("This frame materializes the same accessibility state.")
            )
        } else {
            List {
                if semanticChanges.isEmpty {
                    Section {
                        Label(
                            "No user-facing accessibility changes",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Meaningful changes") {
                        ForEach(semanticChanges) { change in changeRow(change) }
                    }
                }

                if !technicalChanges.isEmpty {
                    Section {
                        Button {
                            showsTechnicalChanges.toggle()
                        } label: {
                            HStack {
                                Label(
                                    "\(technicalChanges.count) layout and hierarchy updates",
                                    systemImage: "square.3.layers.3d"
                                )
                                Spacer()
                                Image(systemName: showsTechnicalChanges ? "chevron.up" : "chevron.down")
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        if showsTechnicalChanges {
                            ForEach(technicalChanges) { change in changeRow(change) }
                        }
                    } footer: {
                        Text("Hidden by default because these usually reflect animation, scrolling, or tree bookkeeping.")
                    }
                }
            }
        }
    }

    private func changeRow(_ change: ReplayAccessibilityChange) -> some View {
        Button { selectedNodeID = change.node.id } label: {
            AccessibilityChangeRow(change: change, step: step)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .disabled(change.kind == .removed)
            .accessibilityValue(selectedNodeID == change.node.id && change.kind != .removed ? "Selected" : "Not selected")
            .listRowBackground(
                selectedNodeID == change.node.id && change.kind != .removed
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
    }

    private func changePriority(_ change: ReplayAccessibilityChange) -> Int {
        if change.changedProperties.contains("focused") { return 0 }
        if change.kind == .removed { return 2 }
        return 1
    }
}

private struct AccessibilityBaselineSummary: View {
    let step: ReplayAccessibilityStep

    private var windows: [ReplayAccessibilityNode] {
        step.nodes.filter { $0.role == "AXWindow" }
    }

    private var focusedNodes: [ReplayAccessibilityNode] {
        step.nodes.filter { $0.focused == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Initial accessibility state", systemImage: "camera.metering.matrix")
                .font(.headline)
            Text("This frame is the baseline for later diffs, not \(step.nodes.count) separate user-facing changes.")
                .foregroundStyle(.secondary)
            if !windows.isEmpty {
                GroupBox("Windows") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(windows) { window in
                            Label(accessibilityNodeName(window), systemImage: "macwindow")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !focusedNodes.isEmpty {
                GroupBox("Initial focus") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(focusedNodes) { node in
                            Label(accessibilityNodeName(node), systemImage: "scope")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Label("Use Tree for the complete hierarchy.", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private struct AccessibilityChangeRow: View {
    let change: ReplayAccessibilityChange
    let step: ReplayAccessibilityStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(accessibilityRoleName(change.node.role))
                    if change.node.focused == true {
                        Label("Focused", systemImage: "scope")
                            .foregroundStyle(.blue)
                    }
                    if change.node.enabled == false {
                        Label("Disabled", systemImage: "nosign")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let breadcrumb = accessibilityBreadcrumb(for: change.node, in: step) {
                    Text(breadcrumb)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                ForEach(propertyDetails.prefix(2), id: \.self) { detail in
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var headline: String { accessibilityChangeHeadline(change) }

    private var propertyDetails: [String] {
        guard let previous = change.previousNode else { return [] }
        return change.changedProperties.compactMap { property in
            switch property {
            case "value": return diff("value", previous.value, change.node.value)
            case "title": return diff("title", previous.title, change.node.title)
            case "label": return diff("label", previous.label, change.node.label)
            case "enabled": return diff("enabled", previous.enabled.map(String.init), change.node.enabled.map(String.init))
            case "focused": return diff("focused", previous.focused.map(String.init), change.node.focused.map(String.init))
            case "frame": return "frame changed"
            case "children": return "child structure changed"
            case "parent": return "moved in hierarchy"
            default: return nil
            }
        }
    }

    private func diff(_ label: String, _ before: String?, _ after: String?) -> String {
        "\(label): \(short(before)) → \(short(after))"
    }

    private func short(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value.count > 60 ? String(value.prefix(57)) + "…" : value
    }

    private var icon: String {
        switch change.kind {
        case .appeared: return "plus.circle.fill"
        case .updated: return "arrow.triangle.2.circlepath.circle.fill"
        case .removed: return "minus.circle.fill"
        }
    }

    private var color: Color {
        switch change.kind {
        case .appeared: return .green
        case .updated: return .orange
        case .removed: return .red
        }
    }
}

struct AccessibilityTreeEntry: Identifiable {
    let node: ReplayAccessibilityNode
    let depth: Int
    let hasChildren: Bool
    var id: String { node.id }
}

private struct AccessibilityTreeView: View {
    let step: ReplayAccessibilityStep
    @Binding var selectedNodeID: String?
    @State private var expandedNodeIDs = Set<String>()

    var body: some View {
        List(visibleEntries) { entry in
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(min(entry.depth, 10)) * 11)
                if entry.hasChildren {
                    Button {
                        if expandedNodeIDs.contains(entry.node.id) {
                            expandedNodeIDs.remove(entry.node.id)
                        } else {
                            expandedNodeIDs.insert(entry.node.id)
                        }
                    } label: {
                        Image(systemName: expandedNodeIDs.contains(entry.node.id)
                              ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(expandedNodeIDs.contains(entry.node.id) ? "Collapse" : "Expand") \(accessibilityNodeName(entry.node))")
                    .accessibilityValue(expandedNodeIDs.contains(entry.node.id) ? "Expanded" : "Collapsed")
                    .frame(width: 14)
                } else {
                    Color.clear.frame(width: 14)
                }
                Button { selectedNodeID = entry.node.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(accessibilityNodeName(entry.node))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(accessibilityRoleName(entry.node.role))
                                if step.changedNodeIDs.contains(entry.node.id) {
                                    Circle().fill(.orange).frame(width: 6, height: 6).help("Changed")
                                }
                                if entry.node.focused == true {
                                    Label("Focused", systemImage: "scope").foregroundStyle(.blue)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(selectedNodeID == entry.node.id ? "Selected" : "Not selected")
            }
            .listRowBackground(
                selectedNodeID == entry.node.id ? Color.accentColor.opacity(0.12) : Color.clear
            )
        }
        .onAppear { resetExpansion() }
        .onChange(of: step.id) { resetExpansion() }
    }

    private var visibleEntries: [AccessibilityTreeEntry] {
        accessibilityTreeEntries(step: step, expandedNodeIDs: expandedNodeIDs)
    }

    private func resetExpansion() {
        expandedNodeIDs = Set(step.nodes.filter { $0.depth < 2 }.map(\.id))
    }
}

func accessibilityTreeEntries(step: ReplayAccessibilityStep, expandedNodeIDs: Set<String>) -> [AccessibilityTreeEntry] {
    let nodes = Dictionary(uniqueKeysWithValues: step.nodes.map { ($0.id, $0) })
    var roots = step.nodes.filter { node in
        node.id == step.rootID || node.parentID == nil || node.parentID.flatMap { nodes[$0] } == nil
    }
    // Find disconnected components independently of expansion. Hidden descendants
    // still belong to their parent; they must never become extra top-level rows.
    var reachable = Set<String>()
    func includeComponent(_ root: ReplayAccessibilityNode) {
        var pending = [root.id]
        while let id = pending.popLast() {
            guard reachable.insert(id).inserted, let node = nodes[id] else { continue }
            pending.append(contentsOf: node.childIDs)
        }
    }
    for root in roots { includeComponent(root) }
    for node in step.nodes where !reachable.contains(node.id) {
        roots.append(node)
        includeComponent(node)
    }
    var visited = Set<String>()
    var result: [AccessibilityTreeEntry] = []

    func append(_ node: ReplayAccessibilityNode, depth: Int) {
        guard visited.insert(node.id).inserted else { return }
        let children = node.childIDs.compactMap { nodes[$0] }
        result.append(AccessibilityTreeEntry(node: node, depth: depth, hasChildren: !children.isEmpty))
        if expandedNodeIDs.contains(node.id) {
            for child in children { append(child, depth: depth + 1) }
        }
    }
    for root in roots { append(root, depth: 0) }
    return result
}

private struct AccessibilityNodeDetail: View {
    let node: ReplayAccessibilityNode
    @State private var showsTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessibilityNodeName(node)).font(.headline).textSelection(.enabled)
                    Text(accessibilityRoleName(node.role)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if node.focused == true { Label("Focused", systemImage: "scope").foregroundStyle(.blue) }
                if node.enabled == false { Label("Disabled", systemImage: "nosign").foregroundStyle(.secondary) }
            }
            if let value = node.value, value != accessibilityNodeName(node) {
                LabeledContent("Value", value: value).textSelection(.enabled)
            }
            if let help = node.help, !help.isEmpty {
                LabeledContent("Help", value: help).textSelection(.enabled)
            }
            DisclosureGroup("Technical details", isExpanded: $showsTechnicalDetails) {
                VStack(alignment: .leading, spacing: 5) {
                    if let identifier = node.identifier, !identifier.isEmpty {
                        LabeledContent("Identifier", value: identifier)
                    }
                    if let frame = node.frame {
                        LabeledContent(
                            "Frame",
                            value: String(format: "%.0f, %.0f · %.0f × %.0f", frame.x, frame.y, frame.width, frame.height)
                        )
                    }
                    HStack {
                        Text(node.id)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(node.id, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy internal node ID")
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }
}

private func accessibilityNodeName(_ node: ReplayAccessibilityNode) -> String {
    for value in [node.title, node.label, node.value, node.identifier] {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
    }
    return accessibilityRoleName(node.role)
}

private func accessibilityChangeHeadline(_ change: ReplayAccessibilityChange) -> String {
    let name = accessibilityNodeName(change.node)
    switch change.kind {
    case .appeared: return "“\(name)” appeared"
    case .removed: return "“\(name)” was removed"
    case .updated:
        if change.changedProperties.contains("focused") {
            return change.node.focused == true ? "Focus moved to “\(name)”" : "“\(name)” lost focus"
        }
        if change.changedProperties.contains("value") { return "“\(name)” changed value" }
        if change.changedProperties.contains("enabled") {
            return "“\(name)” became \(change.node.enabled == false ? "disabled" : "enabled")"
        }
        if change.changedProperties.contains("frame") { return "“\(name)” moved or resized" }
        return "“\(name)” changed"
    }
}

private func timelineApplicationColor(_ applicationID: String) -> Color {
    let palette: [Color] = [.cyan, .green, .yellow, .pink, .indigo, .mint]
    let index = applicationID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
    return palette[index % palette.count]
}

private func accessibilityRoleName(_ role: String?) -> String {
    guard var value = role, !value.isEmpty else { return "Unknown element" }
    if value.hasPrefix("AX") { value.removeFirst(2) }
    var result = ""
    for character in value {
        if character.isUppercase, !result.isEmpty, result.last?.isWhitespace == false { result.append(" ") }
        result.append(character)
    }
    return result
}

private func accessibilityBreadcrumb(
    for node: ReplayAccessibilityNode,
    in step: ReplayAccessibilityStep
) -> String? {
    let nodes = Dictionary(uniqueKeysWithValues: step.nodes.map { ($0.id, $0) })
    var names: [String] = []
    var parentID = node.parentID
    var visited = Set<String>()
    while let id = parentID, visited.insert(id).inserted, let parent = nodes[id] {
        let name = accessibilityNodeName(parent)
        if name != accessibilityRoleName(parent.role) { names.append(name) }
        parentID = parent.parentID
    }
    let path = names.reversed().suffix(3)
    return path.isEmpty ? nil : path.joined(separator: " › ")
}

private func annotationColor(_ kind: RecordingAnnotationKind) -> Color {
    switch kind {
    case .issue: return .red
    case .observation: return .blue
    case .question: return .purple
    case .highlight: return .orange
    }
}

private let playbackRates: [Float] = [0.5, 1, 2, 4, 8]

private func formatPlaybackRate(_ rate: Float) -> String {
    let value = Double(rate)
    if value.rounded() == value { return String(format: "%.0f×", value) }
    if (value * 2).rounded() == value * 2 { return String(format: "%.1f×", value) }
    return String(format: "%.2f×", value)
}

private func formatTime(_ seconds: TimeInterval) -> String {
    let clamped = max(0, seconds)
    return String(
        format: "%02d:%05.2f",
        Int(clamped) / 60,
        clamped.truncatingRemainder(dividingBy: 60)
    )
}
