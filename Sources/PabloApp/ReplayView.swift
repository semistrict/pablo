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
        guard let recording, let selectedStep, selectedStep.id > 0 else { return nil }
        return recording.accessibilitySteps.first { $0.id == selectedStep.id - 1 }
    }

    var selectedNode: ReplayAccessibilityNode? {
        guard let selectedStep, let selectedNodeID else { return nil }
        return selectedStep.nodes.first { $0.id == selectedNodeID }
    }

    var selectedNodeVideoRegion: CGRect? {
        guard let selectedStep, let node = selectedNode, let frame = node.frame,
              frame.width > 0, frame.height > 0 else { return nil }
        let nodesByID = Dictionary(uniqueKeysWithValues: selectedStep.nodes.map { ($0.id, $0) })
        var ancestor: ReplayAccessibilityNode? = node
        var visited = Set<String>()
        var windowFrame: ReplayAccessibilityFrame?
        while let current = ancestor, visited.insert(current.id).inserted {
            if current.role == "AXWindow", let candidate = current.frame {
                windowFrame = candidate
                break
            }
            ancestor = current.parentID.flatMap { nodesByID[$0] }
        }
        guard let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        let region = CGRect(
            x: (frame.x - windowFrame.x) / windowFrame.width,
            y: (frame.y - windowFrame.y) / windowFrame.height,
            width: frame.width / windowFrame.width,
            height: frame.height / windowFrame.height
        )
        let clipped = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    var selectedAnnotation: RecordingAnnotation? {
        guard let selectedAnnotationID else { return nil }
        return annotations.first { $0.id == selectedAnnotationID }
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

    func chooseAndLoadRecording() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Open Pablo Recording"
        panel.prompt = "Review"
        panel.directoryURL = Self.recordingsDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return load(url)
    }

    func selectAccessibilityStep(_ id: Int?, seek: Bool) {
        selectedStepID = id
        guard let step = selectedStep else { return }
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
        if let timestamp = annotation.startTimestampNs {
            seek(to: recording.videoTime(forTimestampNs: timestamp))
        }
        if let reference = annotation.accessibilityReferences.first,
           let step = recording.accessibilitySteps.first(where: { $0.reference == reference }) {
            selectAccessibilityStep(step.id, seek: false)
        }
        selectedNodeID = annotation.accessibilityNodeIDs.first
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
            let annotation = try RecordingAnnotationStore.add(
                to: recording.packageURL,
                draft: RecordingAnnotationDraft(
                    kind: kind,
                    text: text,
                    startTimestampNs: startTimestamp,
                    endTimestampNs: endTimestamp,
                    accessibilityReferences: selectedStep.map { [$0.reference] } ?? [],
                    accessibilityNodeIDs: attachEvidence ? selectedNodeID.map { [$0] } ?? [] : [],
                    trace: trace
                ),
                author: .localHuman
            )
            reloadAnnotations()
            selectedAnnotationID = annotation.id
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
            selectedStepID = recording.accessibilitySteps.first?.id
            selectedNodeID = nil
            selectedAnnotationID = nil
            draftTraceSamples = []
            currentVideoTime = 0
            errorMessage = nil
            player.replaceCurrentItem(with: AVPlayerItem(url: recording.videoURL))
            seekToSelectedStep()
            return true
        } catch {
            recording = nil
            annotations = []
            selectedStepID = nil
            selectedNodeID = nil
            selectedAnnotationID = nil
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

    private static var recordingsDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pablo Recordings", isDirectory: true)
    }
}

struct ReplayView: View {
    @ObservedObject var model: ReplayModel
    @State private var sidebarMode = SidebarMode.markup
    @State private var traceLineWidth = 0.008
    @State private var draftKind = RecordingAnnotationKind.observation
    @State private var attachEvidence = true
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private enum SidebarMode: String, CaseIterable, Identifiable {
        case markup = "Markup"
        case evidence = "Evidence"
        var id: String { rawValue }
    }

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
                    Button("Open Recording…") { _ = model.chooseAndLoadRecording() }
                }
            }
        }
        .navigationTitle(model.recording.map { "Review — \($0.targetName)" } ?? "Pablo Review")
        .toolbar {
            Button("Open Recording…") { _ = model.chooseAndLoadRecording() }
        }
        .onAppear {
            if model.recording == nil { _ = model.loadLatest(preferredURL: nil) }
        }
        .onReceive(timer) { _ in model.updateCurrentVideoTime() }
        .onReceive(NotificationCenter.default.publisher(for: .pabloAnnotationsDidChange)) { note in
            model.reloadAnnotations(changedRecordingPath: note.object as? String)
        }
    }

    private func review(_ recording: ReplayRecording) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                recordingHeader(recording)
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
                    cancelTrace: model.beginTrace
                )
                TransportTimeline(recording: recording, model: model)
            }
            .padding(16)
            .frame(minWidth: 640)

            VStack(spacing: 10) {
                Picker("Review panel", selection: $sidebarMode) {
                    ForEach(SidebarMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 12)

                switch sidebarMode {
                case .markup:
                    MarkupSidebar(
                        model: model,
                        lineWidth: $traceLineWidth,
                        kind: $draftKind,
                        attachEvidence: $attachEvidence
                    )
                case .evidence:
                    EvidenceSidebar(model: model)
                }
            }
            .frame(minWidth: 360, idealWidth: 410, maxWidth: 480)
        }
    }

    private func recordingHeader(_ recording: ReplayRecording) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.targetName).font(.title3.weight(.semibold))
                Text(recording.packageURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(recording.accessibilitySteps.count) frames", systemImage: "accessibility")
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
    let beginTrace: () -> Void
    let appendPoint: (Double, Double) -> Void
    @Binding var annotationKind: RecordingAnnotationKind
    let saveComment: (String) -> Bool
    let cancelTrace: () -> Void
    @State private var isDrawing = false
    @State private var showsCommentBox = false

    var body: some View {
        ZStack {
            VideoPlayer(player: player)
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
                    .gesture(traceGesture(size: geometry.size))
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
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .aspectRatio(recording.videoAspectRatio, contentMode: .fit)
    }

    private func traceGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                if !isDrawing {
                    showsCommentBox = false
                    beginTrace()
                    isDrawing = true
                }
                appendPoint(
                    min(max(value.location.x / size.width, 0), 1),
                    min(max(value.location.y / size.height, 0), 1)
                )
            }
            .onEnded { _ in
                isDrawing = false
                showsCommentBox = true
            }
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

private struct TransportTimeline: View {
    let recording: ReplayRecording
    @ObservedObject var model: ReplayModel

    private var duration: TimeInterval {
        max(0.001, TimeInterval(recording.durationNs ?? 0) / 1_000_000_000)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                Text(formatTime(model.currentVideoTime))
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .frame(width: 60, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { min(model.currentVideoTime, duration) },
                        set: { model.seek(to: $0) }
                    ),
                    in: 0...duration
                )
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
            EvidenceTrack(recording: recording, model: model, duration: duration)
        }
    }
}

private struct EvidenceTrack: View {
    let recording: ReplayRecording
    @ObservedObject var model: ReplayModel
    let duration: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                ForEach(recording.accessibilitySteps) { step in
                    Button { model.selectAccessibilityStep(step.id, seek: true) } label: {
                        Rectangle()
                            .fill(model.selectedStepID == step.id ? Color.blue : Color.blue.opacity(0.45))
                            .frame(width: 2, height: model.selectedStepID == step.id ? 18 : 11)
                    }
                    .buttonStyle(.plain)
                    .position(x: markerX(recording.videoTime(for: step), width: geometry.size.width), y: 10)
                    .help("\(step.reference) · \(formatTime(recording.videoTime(for: step)))")
                }
                ForEach(model.annotations) { annotation in
                    if let timestamp = annotation.startTimestampNs {
                        Button { model.selectAnnotation(annotation.id) } label: {
                            Circle()
                                .fill(annotationColor(annotation.kind))
                                .frame(width: model.selectedAnnotationID == annotation.id ? 11 : 8)
                        }
                        .buttonStyle(.plain)
                        .position(
                            x: markerX(
                                recording.videoTime(forTimestampNs: timestamp),
                                width: geometry.size.width
                            ),
                            y: 10
                        )
                        .help("\(annotation.reference) · \(annotation.text)")
                    }
                }
            }
        }
        .frame(height: 20)
        .accessibilityLabel("Evidence timeline")
    }

    private func markerX(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat(min(max(time / duration, 0), 1)) * max(width - 2, 1) + 1
    }
}

private struct MarkupSidebar: View {
    @ObservedObject var model: ReplayModel
    @Binding var lineWidth: Double
    @Binding var kind: RecordingAnnotationKind
    @Binding var attachEvidence: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Markup") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Kind", selection: $kind) {
                            ForEach(RecordingAnnotationKind.allCases, id: \.self) { value in
                                Text(value.rawValue.capitalized).tag(value)
                            }
                        }
                        .labelsHidden()
                        Label("Draw on the video", systemImage: "scribble.variable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !model.draftTraceSamples.isEmpty {
                            Button {
                                model.beginTrace()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Clear trace")
                        }
                    }
                    if !model.draftTraceSamples.isEmpty {
                        Text("\(model.draftTraceSamples.count) sampled points")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Stroke")
                        Slider(value: $lineWidth, in: 0.003...0.03)
                        Text(String(format: "%.1f%%", lineWidth * 100))
                            .font(.caption.monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    }
                    .font(.caption)
                    Text("Draw while playing for a timed trace. Paused traces stay on one frame.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $attachEvidence) {
                        if let step = model.selectedStep {
                            Text("Attach \(step.reference)" +
                                 (model.selectedNodeID == nil ? "" : " and selected node"))
                        } else {
                            Text("Attach selected evidence")
                        }
                    }
                    .font(.caption)
                    .disabled(model.selectedStep == nil)
                }
                .padding(6)
            }
            .padding(.horizontal, 12)

            HStack {
                Text("Annotations").font(.headline)
                Spacer()
                Text("\(model.annotations.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)

            if model.annotations.isEmpty {
                ContentUnavailableView(
                    "No markup yet",
                    systemImage: "text.bubble",
                    description: Text("Human and agent notes appear here.")
                )
            } else {
                List(model.annotations, selection: $model.selectedAnnotationID) { annotation in
                    AnnotationRow(annotation: annotation)
                        .tag(annotation.id)
                }
                .onChange(of: model.selectedAnnotationID) {
                    model.selectAnnotation(model.selectedAnnotationID)
                }
            }

            if let annotation = model.selectedAnnotation {
                AnnotationDetail(annotation: annotation, model: model)
                    .padding(12)
                    .background(.quaternary.opacity(0.35))
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
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

private struct EvidenceSidebar: View {
    @ObservedObject var model: ReplayModel
    @State private var mode = EvidenceMode.changes

    private enum EvidenceMode: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case tree = "Tree"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let recording = model.recording, let step = model.selectedStep {
                EvidenceFrameHeader(recording: recording, step: step, model: model)

                Picker("Evidence view", selection: $mode) {
                    ForEach(EvidenceMode.allCases) { value in Text(value.rawValue).tag(value) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)

                switch mode {
                case .changes:
                    AccessibilityChangesView(
                        step: step,
                        previousStep: model.previousStep,
                        selectedNodeID: $model.selectedNodeID
                    )
                case .tree:
                    AccessibilityTreeView(
                        step: step,
                        selectedNodeID: $model.selectedNodeID
                    )
                }

                if let node = model.selectedNode {
                    AccessibilityNodeDetail(node: node)
                        .padding(12)
                        .background(.quaternary.opacity(0.3))
                }
            } else {
                ContentUnavailableView("Select evidence", systemImage: "accessibility")
            }
        }
    }
}

private struct EvidenceFrameHeader: View {
    let recording: ReplayRecording
    let step: ReplayAccessibilityStep
    @ObservedObject var model: ReplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(step.id == 0)
                    .buttonStyle(.borderless)
                Picker(
                    "Frame",
                    selection: Binding(
                        get: { model.selectedStepID },
                        set: { model.selectAccessibilityStep($0, seek: true) }
                    )
                ) {
                    ForEach(recording.accessibilitySteps) { candidate in
                        Text("\(candidate.reference) · \(formatTime(recording.videoTime(for: candidate)))")
                            .tag(Optional(candidate.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(step.id + 1 >= recording.accessibilitySteps.count)
                    .buttonStyle(.borderless)
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
        changes.filter(accessibilityChangeIsSemantic)
    }

    private var technicalChanges: [ReplayAccessibilityChange] {
        changes.filter { !accessibilityChangeIsSemantic($0) }
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
        ScrollView {
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

    private var headline: String {
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

private func accessibilityChangeIsSemantic(_ change: ReplayAccessibilityChange) -> Bool {
    if change.changedProperties.contains(where: {
        ["focused", "enabled", "value", "title", "label", "help", "identifier", "role", "subrole"]
            .contains($0)
    }) {
        return true
    }
    guard change.kind != .updated else { return false }
    let name = accessibilityNodeName(change.node)
    let role = accessibilityRoleName(change.node.role)
    return name != role || change.node.focused == true || change.node.enabled == false
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
