import AppKit
import AVFoundation
import AVKit
import PabloCore
import SwiftUI

@MainActor
final class ReplayModel: ObservableObject {
    @Published private(set) var recording: ReplayRecording?
    @Published var selectedStepID: Int?
    @Published private(set) var errorMessage: String?
    let player = AVPlayer()

    func loadLatest(preferredURL: URL?) -> Bool {
        if let preferredURL {
            return load(preferredURL)
        }
        do {
            let directory = Self.recordingsDirectory
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
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
        panel.prompt = "Replay"
        panel.directoryURL = Self.recordingsDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return load(url)
    }

    func seekToSelectedStep() {
        guard let recording,
              let selectedStepID,
              let step = recording.accessibilitySteps.first(where: { $0.id == selectedStepID }) else {
            return
        }
        player.pause()
        player.seek(
            to: CMTime(seconds: recording.videoTime(for: step), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func load(_ url: URL) -> Bool {
        do {
            let recording = try ReplayRecording.load(from: url)
            self.recording = recording
            selectedStepID = recording.accessibilitySteps.first?.id
            errorMessage = nil
            player.replaceCurrentItem(with: AVPlayerItem(url: recording.videoURL))
            seekToSelectedStep()
            return true
        } catch {
            recording = nil
            selectedStepID = nil
            player.replaceCurrentItem(with: nil)
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static var recordingsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("Pablo Recordings", isDirectory: true)
    }
}

struct ReplayView: View {
    @ObservedObject var model: ReplayModel

    var body: some View {
        Group {
            if let recording = model.recording {
                replay(recording)
            } else {
                ContentUnavailableView {
                    Label("No Recording Open", systemImage: "play.rectangle")
                } description: {
                    Text(model.errorMessage ?? "Choose a .pablo recording to replay.")
                } actions: {
                    Button("Open Recording…") { _ = model.chooseAndLoadRecording() }
                }
            }
        }
        .navigationTitle(model.recording.map { "Replay — \($0.targetName)" } ?? "Pablo Replay")
        .toolbar {
            Button("Open Recording…") { _ = model.chooseAndLoadRecording() }
        }
    }

    private func replay(_ recording: ReplayRecording) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                VideoPlayer(player: model.player)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .aspectRatio(16 / 10, contentMode: .fit)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.targetName)
                            .font(.headline)
                        Text(recording.packageURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        "\(recording.accessibilitySteps.count) a11y steps",
                        systemImage: "accessibility"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(minWidth: 540)

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility steps")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                    List(recording.accessibilitySteps, selection: $model.selectedStepID) { step in
                        AccessibilityStepRow(step: step, videoTime: recording.videoTime(for: step))
                            .tag(step.id)
                    }
                    .onChange(of: model.selectedStepID) { model.seekToSelectedStep() }
                }
                .frame(minWidth: 250, idealWidth: 290)

                AccessibilityStepDetail(step: selectedStep(in: recording))
                    .frame(minWidth: 310, idealWidth: 380)
            }
            .frame(minWidth: 570)
        }
    }

    private func selectedStep(in recording: ReplayRecording) -> ReplayAccessibilityStep? {
        guard let selectedStepID = model.selectedStepID else { return nil }
        return recording.accessibilitySteps.first { $0.id == selectedStepID }
    }
}

private struct AccessibilityStepRow: View {
    let step: ReplayAccessibilityStep
    let videoTime: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(step.reference)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(.blue)
                Text(formatTime(videoTime))
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                Spacer()
                Text(step.kind.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(step.kind == "full" ? .blue : .secondary)
            }
            Text(step.reason.replacingOccurrences(of: "input:", with: ""))
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                Label("\(step.changedNodes.count)", systemImage: "arrow.triangle.2.circlepath")
                if !step.removedNodeIDs.isEmpty {
                    Label("\(step.removedNodeIDs.count)", systemImage: "minus.circle")
                }
                Text("\(step.totalNodeCount) total")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct AccessibilityStepDetail: View {
    let step: ReplayAccessibilityStep?

    var body: some View {
        if let step {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.reference)
                                .font(.system(.headline, design: .monospaced, weight: .bold))
                                .foregroundStyle(.blue)
                                .textSelection(.enabled)
                            Text(step.reason)
                                .font(.headline)
                            Text("Accessibility frame \(step.id + 1) · \(step.kind)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(step.reference, forType: .string)
                        } label: {
                            Label("Copy reference", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy \(step.reference)")
                        if step.truncated {
                            Label("Truncated", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Divider()
                    HStack {
                        Text("Accessibility tree (\(step.nodes.count))")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(step.changedNodes.count) changed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(step.nodes) { node in
                        AccessibilityNodeRow(
                            node: node,
                            changed: step.changedNodeIDs.contains(node.id)
                        )
                    }

                    if !step.removedNodeIDs.isEmpty {
                        Divider()
                        Text("Removed nodes (\(step.removedNodeIDs.count))")
                            .font(.subheadline.weight(.semibold))
                        ForEach(step.removedNodeIDs, id: \.self) { id in
                            Text(id)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView("Select an a11y step", systemImage: "accessibility")
        }
    }
}

private struct AccessibilityNodeRow: View {
    let node: ReplayAccessibilityNode
    let changed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(node.role ?? "Unknown role")
                    .font(.caption.weight(.semibold))
                if changed {
                    Text("CHANGED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
                if node.focused == true {
                    Text("FOCUSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.blue)
                }
            }
            if let name = firstNonempty(node.title, node.label, node.value) {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Text(node.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(9)
        .padding(.leading, CGFloat(min(node.depth, 8)) * 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func firstNonempty(_ values: String?...) -> String? {
        values.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first
    }
}

private func formatTime(_ seconds: TimeInterval) -> String {
    let clamped = max(0, seconds)
    let minutes = Int(clamped) / 60
    return String(format: "%02d:%05.2f", minutes, clamped.truncatingRemainder(dividingBy: 60))
}
