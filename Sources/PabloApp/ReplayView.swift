import AppKit
import AVFoundation
import AVKit
import Combine
import PabloCore
import SwiftUI

extension Notification.Name {
    static let pabloAnnotationsDidChange = Notification.Name("PabloAnnotationsDidChange")
    static let pabloOpenRecordingRequested = Notification.Name("PabloOpenRecordingRequested")
}

@MainActor
protocol RRWebPlaybackControlling: AnyObject {
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    func setPlaybackRate(_ rate: Float)
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
    @Published private var source: ReplaySource?
    @Published private(set) var libraryItems: [ReplayLibraryItem] = []
    @Published private(set) var selectedLibraryItemID: String?
    @Published private(set) var selectedStepID: Int?
    @Published var selectedNodeID: String?
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
        focusedWindowID = id
        beginTrace()
    }

    var selectedNodeVideoRegion: CGRect? {
        guard let node = selectedNode, let frame = node.frame,
              frame.width > 0, frame.height > 0 else { return nil }
        let referenceFrame = recording.map { capture in
            ReplayAccessibilityFrame(
                x: capture.captureFrame.x, y: capture.captureFrame.y,
                width: capture.captureFrame.width, height: capture.captureFrame.height
            )
        }
        guard let referenceFrame, referenceFrame.width > 0, referenceFrame.height > 0 else { return nil }
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
            guard (try? ReplayRecording.load(from: url)) != nil else { return nil }
            return ReplayLibraryItem(
                packageURL: url,
                kind: .native,
                title: url.deletingPathExtension().lastPathComponent,
                detail: "Video and accessibility evidence",
                modifiedAt: modifiedAt
            )
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func selectAccessibilityStep(_ id: Int?, seek: Bool) {
        selectedStepID = id
        guard let step = selectedStep else { return }
        if seek { selectedTimelineItemID = "accessibility:\(step.id)" }
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
        let value = min(max(0, seconds), duration)
        if webRecording != nil {
            webPlaybackController?.pause()
            webPlaybackController?.seek(to: value)
        } else {
            player.pause()
            player.seek(
                to: CMTime(seconds: value, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        isPlaying = false
        currentVideoTime = value
        if synchronizeEvidence { synchronizeTimeDependentUI(to: value) }
    }

    func togglePlayback() {
        if webRecording != nil {
            if isPlaying {
                webPlaybackController?.pause()
                isPlaying = false
            } else {
                webPlaybackController?.setPlaybackRate(playbackRate)
                webPlaybackController?.play()
                isPlaying = true
            }
            return
        }
        if isPlaying || player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.defaultRate = playbackRate
            player.play()
            isPlaying = true
        }
    }

    func setPlaybackRate(_ rate: Float) {
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
        if abs(value - currentVideoTime) > 0.0005 { currentVideoTime = value }
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
        draftTraceSamples.append(sample)
        currentVideoTime = seconds
    }

    func selectAnnotation(_ id: UUID?) {
        selectedAnnotationID = id
        guard let annotation = selectedAnnotation else { return }
        selectedTimelineItemID = "annotation:\(annotation.id.uuidString)"
        if let timestamp = annotation.startTimestampNs {
            seek(to: videoTime(forTimestampNs: timestamp))
        }
        guard let recording else { return }
        if let reference = annotation.accessibilityReferences.first,
           let step = recording.accessibilitySteps.first(where: { $0.reference == reference }) {
            selectAccessibilityStep(step.id, seek: false)
        }
        selectedNodeID = annotation.accessibilityNodeIDs.first
    }

    func selectTimelineItem(_ item: ReplayTimelineItem) {
        selectedTimelineItemID = item.id
        seek(to: videoTime(forTimestampNs: item.timestampNs))
        guard let reference = item.references.first else { return }
        switch reference {
        case .accessibility(let id):
            selectAccessibilityStep(id, seek: false)
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

    func addHumanAnnotation(
        text: String,
        kind: RecordingAnnotationKind,
        attachEvidence: Bool,
        lineWidth: Double
    ) -> Bool {
        guard let packageURL else { return false }
        do {
            if recording == nil {
                let timestamp = sessionTimestampNs(forVideoTime: currentVideoTime)
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
                reloadAnnotations()
                selectAnnotation(annotation.id)
                errorMessage = nil
                return true
            }
            guard let recording else { return false }
            let selectedStep = attachEvidence ? self.selectedStep : nil
            let currentTimestamp = recording.sessionTimestampNs(forVideoTime: currentVideoTime)
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
                    accessibilityNodeIDs: attachEvidence ? selectedNodeID.map { [$0] } ?? [] : [],
                    trace: trace
                ),
                author: .localHuman
            )
            reloadAnnotations()
            selectAnnotation(annotation.id)
            draftTraceSamples = []
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
            reloadAnnotations()
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
            annotations = try RecordingAnnotationStore.load(from: packageURL)
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
        videoLoadTask?.cancel()
        videoLoadID = UUID()
        videoIsLoading = false
        focusedWindowID = nil
        do {
            if let webRecording = try? PabloRRWebRecordingStorage.load(url) {
                let replayData = try PabloRRWebReplayData(recording: webRecording)
                source = .web(webRecording, replayData)
                annotations = try RecordingAnnotationStore.load(from: url)
                timelineItems = replayData.timelineItems(annotations: annotations)
                selectedStepID = nil
                player.replaceCurrentItem(with: nil)
            } else {
                let recording = try ReplayRecording.load(from: url)
                source = .native(recording)
                annotations = recording.annotations
                timelineItems = recording.timelineItems(annotations: annotations)
                selectedStepID = recording.accessibilitySteps.first?.id
                player.replaceCurrentItem(with: nil)
                prepareVideo(recording)
            }
            selectedNodeID = nil
            selectedAnnotationID = nil
            selectedTimelineItemID = nil
            draftTraceSamples = []
            currentVideoTime = 0
            isPlaying = false
            errorMessage = nil
            selectedLibraryItemID = url.standardizedFileURL.path
            seekToSelectedStep()
            return true
        } catch {
            source = nil
            annotations = []
            timelineItems = []
            selectedStepID = nil
            selectedNodeID = nil
            selectedAnnotationID = nil
            selectedTimelineItemID = nil
            player.replaceCurrentItem(with: nil)
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
                await self.player.seek(to: CMTime(seconds: self.currentVideoTime, preferredTimescale: 600))
                guard self.videoLoadID == loadID, !Task.isCancelled else { return }
                self.player.defaultRate = self.playbackRate
                if self.isPlaying { self.player.play() }
                self.videoIsLoading = false
            } catch {
                guard let self, self.videoLoadID == loadID, !Task.isCancelled else { return }
                self.videoIsLoading = false
                self.isPlaying = false
                self.errorMessage = error.localizedDescription
            }
        }
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
        let value = min(max(time, 0), duration)
        if abs(value - currentVideoTime) > 0.0005 { currentVideoTime = value }
        isPlaying = playing && value < max(0, duration - 0.001)
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
        guard let step = recording?.accessibilityStep(atVideoTime: seconds),
              step.id != selectedStepID else { return }
        selectAccessibilityStep(step.id, seek: false)
    }

    static var recordingsDirectory: URL {
        PabloRecordingStorage.localRecordingsDirectory
    }
}

private enum VideoReviewTool: String, CaseIterable, Identifiable {
    case review = "Review"
    case pen = "Pen"
    case comment = "Comment"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .review: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .comment: return "text.bubble"
        }
    }

    var guidance: String {
        switch self {
        case .review: return "Select existing notes"
        case .pen: return "Draw directly on the video"
        case .comment: return "Place a point comment"
        }
    }
}

struct ReplayView: View {
    @ObservedObject var model: ReplayModel
    let openRecordings: @MainActor () -> Void
    @State private var traceLineWidth = 0.008
    @State private var draftKind = RecordingAnnotationKind.observation
    @State private var attachEvidence = true
    @State private var inspectorVisible = true
    @State private var videoTool = VideoReviewTool.pen
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HSplitView {
            RecordingBrowser(model: model, openRecordings: openRecordings)
                .frame(minWidth: 220, idealWidth: 255, maxWidth: 310)

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
            Button("Open Recordings…", action: openRecordings)
            Button {
                withAnimation(.snappy) { inspectorVisible.toggle() }
            } label: {
                Label(
                    inspectorVisible ? "Hide Inspector" : "Show Inspector",
                    systemImage: "sidebar.trailing"
                )
            }
            .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
        }
        .onReceive(timer) { _ in model.updateCurrentVideoTime() }
        .onReceive(NotificationCenter.default.publisher(for: .pabloAnnotationsDidChange)) { note in
            model.reloadAnnotations(changedRecordingPath: note.object as? String)
        }
    }

    private func webReview(_ recording: PabloRRWebRecording) -> some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1_080
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    webReviewMain(recording)
                        .frame(maxWidth: .infinity)
                    if inspectorVisible && !compact {
                        Divider()
                        ReviewInspector(
                            model: model,
                            lineWidth: $traceLineWidth,
                            kind: $draftKind,
                            attachEvidence: $attachEvidence,
                            close: { withAnimation(.snappy) { inspectorVisible = false } }
                        )
                        .frame(width: 410)
                    }
                }
                if inspectorVisible && compact {
                    ReviewInspector(
                        model: model,
                        lineWidth: $traceLineWidth,
                        kind: $draftKind,
                        attachEvidence: $attachEvidence,
                        close: { withAnimation(.snappy) { inspectorVisible = false } }
                    )
                    .frame(width: min(430, geometry.size.width * 0.82))
                    .background(.regularMaterial)
                    .overlay(alignment: .leading) { Divider() }
                    .shadow(color: .black.opacity(0.35), radius: 22, x: -8)
                }
            }
            .onAppear { if compact { inspectorVisible = false } }
            .onChange(of: compact) { _, isCompact in if isCompact { inspectorVisible = false } }
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
        GeometryReader { geometry in
            let compact = geometry.size.width < 1_080
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    reviewMain(recording)
                        .frame(maxWidth: .infinity)
                    if inspectorVisible && !compact {
                        Divider()
                        ReviewInspector(
                            model: model,
                            lineWidth: $traceLineWidth,
                            kind: $draftKind,
                            attachEvidence: $attachEvidence,
                            close: { withAnimation(.snappy) { inspectorVisible = false } }
                        )
                        .frame(width: 410)
                    }
                }

                if inspectorVisible && compact {
                    ReviewInspector(
                        model: model,
                        lineWidth: $traceLineWidth,
                        kind: $draftKind,
                        attachEvidence: $attachEvidence,
                        close: { withAnimation(.snappy) { inspectorVisible = false } }
                    )
                    .frame(width: min(430, geometry.size.width * 0.82))
                    .background(.regularMaterial)
                    .overlay(alignment: .leading) { Divider() }
                    .shadow(color: .black.opacity(0.35), radius: 22, x: -8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onAppear {
                if compact { inspectorVisible = false }
            }
            .onChange(of: compact) { _, isCompact in
                if isCompact { inspectorVisible = false }
            }
        }
    }

    private func reviewMain(_ recording: ReplayRecording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingHeader(recording)
            Picker("View", selection: Binding(
                get: { model.focusedWindowID },
                set: { model.focusWindow($0) }
            )) {
                Text("All windows").tag(String?.none)
                ForEach(recording.windows, id: \.id) { window in
                    Text(window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Window \(window.systemWindowID)")
                        .tag(Optional(window.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 420, alignment: .leading)
            videoToolPicker
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
                selectedNodeName: model.selectedNode.map(accessibilityNodeName),
                tool: videoTool,
                beginTrace: model.beginTrace,
                appendPoint: model.appendTracePoint,
                annotationKind: $draftKind,
                saveComment: { text in
                    model.addHumanAnnotation(
                        text: text,
                        kind: draftKind,
                        attachEvidence: attachEvidence,
                        lineWidth: traceLineWidth
                    )
                },
                cancelTrace: model.beginTrace,
                selectAnnotation: model.selectAnnotation
            )
            .overlay {
                if model.videoIsLoading {
                    ProgressView("Preparing recording…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            UnifiedTimeline(model: model)
        }
        .padding(16)
        .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)
    }

    private var videoToolPicker: some View {
        HStack(spacing: 10) {
            Picker("Video tool", selection: $videoTool) {
                ForEach(VideoReviewTool.allCases) { tool in
                    Label(tool.rawValue, systemImage: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 310)
            .accessibilityLabel("Video interaction tool")

            Text(videoTool.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func recordingHeader(_ recording: ReplayRecording) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.scopeName).font(.title3.weight(.semibold))
                Text(recording.packageURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(recording.accessibilitySteps.count) frames", systemImage: "accessibility")
            if let workspace = model.currentWorkspace {
                if let frontmostID = workspace.frontmostApplicationID {
                    let applicationName = model.applicationName(for: frontmostID)
                    Label(applicationName, systemImage: "app.fill")
                    if let windowTitle = workspace.windows
                        .filter({ $0.applicationID == frontmostID && $0.isOnScreen })
                        .min(by: { $0.zOrder < $1.zOrder })?.title,
                       !windowTitle.isEmpty,
                       windowTitle.caseInsensitiveCompare(applicationName) != .orderedSame {
                        Text(windowTitle).lineLimit(1)
                    }
                }
                Label("\(workspace.applications.count) apps", systemImage: "square.grid.2x2")
                Label("\(workspace.windows.count) windows", systemImage: "macwindow.on.rectangle")
            }
            Label("\(model.annotations.count) notes", systemImage: "text.bubble")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
    let selectedNodeName: String?
    let tool: VideoReviewTool
    let beginTrace: () -> Void
    let appendPoint: (Double, Double) -> Void
    @Binding var annotationKind: RecordingAnnotationKind
    let saveComment: (String) -> Bool
    let cancelTrace: () -> Void
    let selectAnnotation: (UUID?) -> Void
    @State private var isInteracting = false
    @State private var showsCommentBox = false
    @State private var annotationCandidateID: UUID?
    @State private var gestureStart: CGPoint?
    @State private var gestureTool: VideoReviewTool?

    var body: some View {
        ZStack {
            GeometryReader { geometry in
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
                        label: selectedNodeName,
                        size: geometry.size
                    )
                }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(videoGesture(size: geometry.size))
                if showsCommentBox, let endpoint = draftSamples.last {
                    DraftCommentBubble(
                        kind: $annotationKind,
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
        .help(tool.guidance)
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
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.blue.opacity(0.12))
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
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
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
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
            HStack(spacing: 10) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                Button { model.moveToMeaningfulTimelineItem(-1) } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.borderless)
                .help("Previous meaningful event")
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button { model.moveToMeaningfulTimelineItem(1) } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.borderless)
                .help("Next meaningful event")
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Text(formatTime(model.currentVideoTime))
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .frame(width: 60, alignment: .leading)
                Spacer()
                Button { panViewport(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(zoom == 1)
                .help("Pan timeline backward without seeking")
                Button {
                    followsPlayhead = true
                    viewportCenter = model.currentVideoTime
                } label: {
                    Image(systemName: followsPlayhead ? "scope" : "dot.scope")
                }
                .buttonStyle(.borderless)
                .disabled(zoom == 1 && followsPlayhead)
                .help("Follow playhead")
                Button { panViewport(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(zoom == 1)
                .help("Pan timeline forward without seeking")
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...12)
                    .frame(width: 110)
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
                .help("Fit entire recording")
                Text(formatTime(duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Picker(
                    "Playback speed",
                    selection: Binding(
                        get: { model.playbackRate },
                        set: { model.setPlaybackRate($0) }
                    )
                ) {
                    ForEach(playbackRates, id: \.self) { rate in
                        Text(formatPlaybackRate(rate)).tag(rate)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Playback speed")
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
        .padding(10)
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
    @State private var evidenceMode = InspectorEvidenceMode.changes
    @State private var showsEvidenceDetails = false
    @State private var quickNoteText = ""

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
                    .help("Hide Inspector")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        TextField("Note at playhead…", text: $quickNoteText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addQuickNote)
                        Button("Add", action: addQuickNote)
                            .buttonStyle(.borderedProminent)
                            .disabled(quickNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let item = model.selectedTimelineItem {
                        SelectedTimelineContext(item: item, model: model)
                    }

                    if let event = model.selectedWebEvent {
                        WebEventDetail(event: event)
                    }

                    annotationSection

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
                                        selectedNodeID: $model.selectedNodeID
                                    )
                                    .frame(minHeight: 170, maxHeight: 300)
                                case .tree:
                                    AccessibilityTreeView(
                                        step: step,
                                        selectedNodeID: $model.selectedNodeID
                                    )
                                    .frame(minHeight: 220, maxHeight: 360)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }

                    if let node = model.selectedNode {
                        AccessibilityNodeDetail(node: node)
                            .padding(10)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
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
        let text = quickNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.beginTrace()
        if model.addHumanAnnotation(
            text: text,
            kind: kind,
            attachEvidence: attachEvidence,
            lineWidth: lineWidth
        ) {
            quickNoteText = ""
        }
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
                     ? "Click or draw on the video to add a spatial note."
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
                    .disabled(step.id == 0)
                    .buttonStyle(.borderless)
                Text(step.reference)
                    .font(.caption.monospaced().weight(.bold))
                    .textSelection(.enabled)
                Text("\(step.id + 1) of \(recording.accessibilitySteps.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(step.id + 1 >= recording.accessibilitySteps.count)
                    .buttonStyle(.borderless)
                Button {
                    frameReference = step.reference
                    showsFrameJump = true
                } label: {
                    Image(systemName: "number")
                }
                .buttonStyle(.borderless)
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
        AccessibilityChangeRow(change: change, step: step)
            .contentShape(Rectangle())
            .onTapGesture {
                if change.kind != .removed { selectedNodeID = change.node.id }
            }
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

private struct AccessibilityTreeEntry: Identifiable {
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
                    .frame(width: 14)
                } else {
                    Color.clear.frame(width: 14)
                }
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
            .onTapGesture { selectedNodeID = entry.node.id }
            .listRowBackground(
                selectedNodeID == entry.node.id ? Color.accentColor.opacity(0.12) : Color.clear
            )
        }
        .onAppear { resetExpansion() }
        .onChange(of: step.id) { resetExpansion() }
    }

    private var visibleEntries: [AccessibilityTreeEntry] {
        let nodes = Dictionary(uniqueKeysWithValues: step.nodes.map { ($0.id, $0) })
        let roots = step.nodes.filter { node in
            node.id == step.rootID || node.parentID == nil || node.parentID.flatMap { nodes[$0] } == nil
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
        for node in step.nodes where !visited.contains(node.id) { append(node, depth: 0) }
        return result
    }

    private func resetExpansion() {
        expandedNodeIDs = Set(step.nodes.filter { $0.depth < 2 }.map(\.id))
    }
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
