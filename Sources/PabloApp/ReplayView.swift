import AppKit
import AVFoundation
import AVKit
import Combine
import PabloCore
import SwiftUI

extension Notification.Name {
    static let pabloAnnotationsDidChange = Notification.Name("PabloAnnotationsDidChange")
}

@MainActor
final class ReplayModel: ObservableObject {
    @Published private(set) var recording: ReplayRecording?
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

    var selectedNodeVideoRegion: CGRect? {
        guard let selectedStep, let node = selectedNode, let frame = node.frame,
              frame.width > 0, frame.height > 0 else { return nil }
        let nodesByID = Dictionary(uniqueKeysWithValues: selectedStep.nodes.map { ($0.id, $0) })
        var ancestor: ReplayAccessibilityNode? = node
        var visited = Set<String>()
        let referenceFrame: ReplayAccessibilityFrame?
        if recording?.scope == .display, let capture = recording?.captureFrame {
            referenceFrame = ReplayAccessibilityFrame(
                x: capture.x, y: capture.y, width: capture.width, height: capture.height
            )
        } else {
            var windowFrame: ReplayAccessibilityFrame?
            while let current = ancestor, visited.insert(current.id).inserted {
                if current.role == "AXWindow", let candidate = current.frame {
                    windowFrame = candidate
                    break
                }
                ancestor = current.parentID.flatMap { nodesByID[$0] }
            }
            referenceFrame = windowFrame
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

    func loadLatest(preferredURL: URL?) -> Bool {
        if let preferredURL { return load(preferredURL) }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: Self.recordingsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            guard let latest = urls
                .filter({ $0.pathExtension == "pablo" })
                .max(by: { modificationDate($0) < modificationDate($1) }) else {
                errorMessage = "No Pablo recordings were found."
                return false
            }
            return load(latest)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
        let value = max(0, seconds)
        player.pause()
        isPlaying = false
        player.seek(
            to: CMTime(seconds: value, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentVideoTime = value
        if synchronizeEvidence { synchronizeTimeDependentUI(to: value) }
    }

    func togglePlayback() {
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
        playbackRate = min(max(rate, 0.25), 3)
        player.defaultRate = playbackRate
        if isPlaying || player.timeControlStatus == .playing {
            player.rate = playbackRate
            isPlaying = true
        }
    }

    func updateCurrentVideoTime() {
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
        guard let recording, let annotation = selectedAnnotation else { return }
        selectedTimelineItemID = "annotation:\(annotation.id.uuidString)"
        if let timestamp = annotation.startTimestampNs {
            seek(to: recording.videoTime(forTimestampNs: timestamp))
        }
        if let reference = annotation.accessibilityReferences.first,
           let step = recording.accessibilitySteps.first(where: { $0.reference == reference }) {
            selectAccessibilityStep(step.id, seek: false)
        }
        selectedNodeID = annotation.accessibilityNodeIDs.first
    }

    func selectTimelineItem(_ item: ReplayTimelineItem) {
        selectedTimelineItemID = item.id
        seek(to: recording?.videoTime(forTimestampNs: item.timestampNs) ?? 0)
        guard let reference = item.references.first else { return }
        switch reference {
        case .accessibility(let id):
            selectAccessibilityStep(id, seek: false)
        case .annotation(let id):
            selectAnnotation(id)
        case .workspace, .input, .automation:
            break
        }
    }

    func moveToMeaningfulTimelineItem(_ direction: Int) {
        guard let recording else { return }
        let currentTimestamp = recording.sessionTimestampNs(forVideoTime: currentVideoTime)
        let items = recording.meaningfulTimelineItems(annotations: annotations)
        let item = direction < 0
            ? items.last(where: { $0.timestampNs + 1_000_000 < currentTimestamp })
            : items.first(where: { $0.timestampNs > currentTimestamp + 1_000_000 })
        if let item { selectTimelineItem(item) }
    }

    func applicationName(for id: String) -> String {
        guard let recording else { return id }
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
        guard let recording else { return false }
        do {
            let selectedStep = attachEvidence ? self.selectedStep : nil
            let currentTimestamp = recording.sessionTimestampNs(forVideoTime: currentVideoTime)
            let trace = draftTraceSamples.isEmpty
                ? nil
                : RecordingAnnotationTrace(samples: draftTraceSamples, lineWidth: lineWidth)
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
        guard let recording, let annotation = selectedAnnotation else { return }
        do {
            let updated = try RecordingAnnotationStore.resolve(
                in: recording.packageURL,
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
        guard let recording else { return }
        if let changedRecordingPath,
           URL(fileURLWithPath: changedRecordingPath).standardizedFileURL !=
            recording.packageURL.standardizedFileURL {
            return
        }
        do {
            annotations = try RecordingAnnotationStore.load(from: recording.packageURL)
            timelineItems = recording.timelineItems(annotations: annotations)
            if let selectedAnnotationID,
               !annotations.contains(where: { $0.id == selectedAnnotationID }) {
                self.selectedAnnotationID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load(_ url: URL) -> Bool {
        do {
            let recording = try ReplayRecording.load(from: url)
            self.recording = recording
            annotations = recording.annotations
            timelineItems = recording.timelineItems(annotations: annotations)
            selectedStepID = recording.accessibilitySteps.first?.id
            selectedNodeID = nil
            selectedAnnotationID = nil
            selectedTimelineItemID = nil
            draftTraceSamples = []
            currentVideoTime = 0
            errorMessage = nil
            player.replaceCurrentItem(with: AVPlayerItem(url: recording.videoURL))
            seekToSelectedStep()
            return true
        } catch {
            recording = nil
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
        Group {
            if let recording = model.recording {
                review(recording)
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
        .navigationTitle(
            model.recording?.packageURL.deletingPathExtension().lastPathComponent ?? "Pablo Review"
        )
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
            videoToolPicker
            VideoMarkupCanvas(
                recording: recording,
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
            UnifiedTimeline(recording: recording, model: model)
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

private struct VideoMarkupCanvas: View {
    let recording: ReplayRecording
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
            VideoPlayer(player: player)
                .accessibilityHidden(true)
            GeometryReader { geometry in
                TraceOverlay(
                    recording: recording,
                    annotations: annotations,
                    selectedAnnotationID: selectedAnnotationID,
                    currentVideoTime: currentVideoTime,
                    draftSamples: draftSamples,
                    draftLineWidth: draftLineWidth
                )
                if let selectedNodeRegion {
                    AccessibilityBoundsOverlay(
                        region: selectedNodeRegion,
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
        }
        .aspectRatio(recording.videoAspectRatio, contentMode: .fit)
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
        appendPoint(
            min(max(point.x / size.width, 0), 1),
            min(max(point.y / size.height, 0), 1)
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
            let points = samples.map { CGPoint(x: size.width * $0.x, y: size.height * $0.y) }
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
        let point = CGPoint(x: size.width * endpoint.x, y: size.height * endpoint.y)
        let halfWidth: CGFloat = 135
        let proposedX = endpoint.x > 0.62
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
                    samples,
                    lineWidth: trace.lineWidth,
                    color: annotationColor(annotation.kind),
                    emphasized: annotation.id == selectedAnnotationID,
                    in: &context,
                    size: size
                )
            }
            draw(
                draftSamples,
                lineWidth: draftLineWidth,
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
    let recording: ReplayRecording
    @ObservedObject var model: ReplayModel
    @State private var zoom = 1.0
    @State private var viewportCenter: TimeInterval?
    @State private var followsPlayhead = true

    private var duration: TimeInterval {
        max(0.001, TimeInterval(recording.durationNs ?? 0) / 1_000_000_000)
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
                ForEach(ReplayTimelineLane.allCases, id: \.self) { lane in
                    TimelineLaneRow(
                        lane: lane,
                        recording: recording,
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
    let recording: ReplayRecording
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
        recording.timelineClusters(
            from: model.timelineItems,
            lane: lane,
            visibleTimestampRange: recording.sessionTimestampNs(forVideoTime: visibleRange.lowerBound)...recording.sessionTimestampNs(forVideoTime: visibleRange.upperBound),
            trackWidth: width
        )
    }

    private func x(forTimestamp timestamp: UInt64, width: CGFloat) -> CGFloat {
        x(forTime: recording.videoTime(forTimestampNs: timestamp), width: width)
    }

    private func x(forTime time: TimeInterval, width: CGFloat) -> CGFloat {
        let duration = max(visibleRange.upperBound - visibleRange.lowerBound, 0.001)
        return CGFloat(min(max((time - visibleRange.lowerBound) / duration, 0), 1)) * max(width - 8, 1) + 4
    }

    private func clusterHelp(_ cluster: ReplayTimelineCluster) -> String {
        if cluster.items.count == 1, let item = cluster.items.first {
            return "\(item.title) · \(formatTime(recording.videoTime(forTimestampNs: item.timestampNs)))"
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
        case .annotation: return "NOTES"
        }
    }

    private var laneIcon: String {
        switch lane {
        case .workspace: return "macwindow.on.rectangle"
        case .input: return "cursorarrow.click"
        case .automation: return "cpu"
        case .accessibility: return "accessibility"
        case .annotation: return "text.bubble"
        }
    }

    private var laneColor: Color {
        switch lane {
        case .workspace: return .teal
        case .input: return .secondary
        case .automation: return .purple
        case .accessibility: return .blue
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
                Text("Click or draw on the video to add a spatial note.")
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
                if let recording = model.recording {
                    Text(formatTime(recording.videoTime(forTimestampNs: item.timestampNs)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
        case .annotation: return "text.bubble"
        }
    }
    private var laneColor: Color {
        switch item.lane {
        case .workspace: return .teal
        case .input: return .secondary
        case .automation: return .purple
        case .accessibility: return .blue
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

private let playbackRates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]

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
