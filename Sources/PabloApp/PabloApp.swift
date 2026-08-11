import AppKit
import PabloCore
import SwiftUI

@main
struct PabloMenuBarApp: App {
    @NSApplicationDelegateAdaptor(PabloApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = RecorderModel()
    @StateObject private var replayModel = ReplayModel()

    var body: some Scene {
        MenuBarExtra {
            RecorderPanel(model: model, replayModel: replayModel, showsOpenWindowButton: true)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(model.statusTitle)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Pablo", id: "recorder") {
            RecorderPanel(model: model, replayModel: replayModel, showsOpenWindowButton: false)
        }
        .defaultSize(width: 360, height: 440)
        .windowResizability(.contentSize)

        WindowGroup("Pablo Replay", id: "replay") {
            ReplayView(model: replayModel)
        }
        .defaultSize(width: 1_180, height: 720)
    }
}

final class PabloApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
final class RecorderModel: ObservableObject {
    struct AppChoice: Identifiable, Hashable {
        let pid: pid_t
        let name: String
        let bundleIdentifier: String?
        var id: pid_t { pid }
    }

    enum Status: Equatable {
        case idle
        case starting
        case recording
        case paused
        case stopping
    }

    @Published var applications: [AppChoice] = []
    @Published var selectedPID: pid_t?
    @Published var status: Status = .idle
    @Published var elapsedNanoseconds: UInt64 = 0
    @Published var errorMessage: String?
    @Published var lastRecordingURL: URL?
    @Published var captureText = true

    private var session: RecordingSession?

    var statusTitle: String {
        switch status {
        case .idle: return "Ready"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Finishing…"
        }
    }

    var menuBarSymbol: String {
        switch status {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .starting, .stopping: return "circle.dotted"
        case .idle: return "record.circle"
        }
    }

    var canStart: Bool { status == .idle && selectedPID != nil }
    var isActive: Bool { status == .recording || status == .paused }

    func refreshApplications() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        applications = NSWorkspace.shared.runningApplications
            .filter {
                !$0.isTerminated && $0.processIdentifier != ownPID &&
                $0.activationPolicy == .regular && $0.localizedName != nil
            }
            .map {
                AppChoice(
                    pid: $0.processIdentifier,
                    name: $0.localizedName ?? "PID \($0.processIdentifier)",
                    bundleIdentifier: $0.bundleIdentifier
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if selectedPID == nil || !applications.contains(where: { $0.pid == selectedPID }) {
            selectedPID = NSWorkspace.shared.frontmostApplication.flatMap { frontmost in
                applications.first(where: { $0.pid == frontmost.processIdentifier })?.pid
            } ?? applications.first?.pid
        }
    }

    func startRecording() async {
        guard canStart, let selectedPID else { return }
        errorMessage = nil
        status = .starting
        do {
            var options = RecordOptions()
            options.pid = selectedPID
            options.outputURL = try nextRecordingURL()
            options.captureText = captureText
            let session = try RecordingSession(options: options)
            self.session = session
            try await session.start()
            lastRecordingURL = session.packageURL
            elapsedNanoseconds = 0
            status = .recording
        } catch {
            session = nil
            status = .idle
            errorMessage = error.localizedDescription
        }
    }

    func togglePause() {
        switch status {
        case .recording:
            session?.pause()
            elapsedNanoseconds = session?.durationNs ?? elapsedNanoseconds
            status = .paused
        case .paused:
            session?.resume()
            status = .recording
        default:
            break
        }
    }

    func stopRecording() async {
        guard isActive else { return }
        status = .stopping
        do {
            try await session?.stop()
        } catch {
            errorMessage = error.localizedDescription
        }
        elapsedNanoseconds = session?.durationNs ?? elapsedNanoseconds
        session = nil
        status = .idle
        refreshApplications()
    }

    func updateElapsedTime() {
        guard isActive else { return }
        if session?.captureEnded == true {
            Task { await stopRecording() }
        } else if status == .recording {
            elapsedNanoseconds = session?.durationNs ?? elapsedNanoseconds
        }
    }

    func revealRecordings() {
        let url = lastRecordingURL?.deletingLastPathComponent() ?? Self.recordingsDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting(lastRecordingURL.map { [$0] } ?? [url])
    }

    func openPrivacySettings(_ pane: PrivacyPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func nextRecordingURL() throws -> URL {
        let directory = Self.recordingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Recording \(formatter.string(from: Date())).pablo"
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    private static var recordingsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("Pablo Recordings", isDirectory: true)
    }
}

enum PrivacyPane: String, CaseIterable, Identifiable {
    case accessibility = "Accessibility"
    case inputMonitoring = "Input Monitoring"
    case screenRecording = "Screen Recording"

    var id: String { rawValue }

    var urlString: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }
}

private struct RecorderPanel: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var replayModel: ReplayModel
    let showsOpenWindowButton: Bool
    @Environment(\.openWindow) private var openWindow
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear { model.refreshApplications() }
        .onReceive(timer) { _ in model.updateElapsedTime() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: model.menuBarSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Pablo")
                    .font(.headline)
                Text(model.statusTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isActive || model.status == .stopping {
                Text(formattedDuration)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .contentTransition(.numericText())
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isActive || model.status == .stopping {
                activeControls
            } else {
                targetControls
            }

            if let error = model.errorMessage {
                errorCard(error)
            }
        }
        .padding(14)
    }

    private var targetControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Record application")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    model.refreshApplications()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh running applications")
            }

            Picker("Application", selection: $model.selectedPID) {
                Text("Choose an application…").tag(pid_t?.none)
                ForEach(model.applications) { application in
                    Text(application.name).tag(Optional(application.pid))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Capture typed text", isOn: $model.captureText)
                .font(.caption)

            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(!model.canStart)
        }
    }

    private var activeControls: some View {
        VStack(spacing: 12) {
            if let application = model.applications.first(where: { $0.pid == model.selectedPID }) {
                HStack {
                    Image(systemName: "macwindow")
                        .foregroundStyle(.secondary)
                    Text(application.name)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(model.status == .paused ? "PAUSED" : "LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(model.status == .paused ? .orange : .red)
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.togglePause()
                } label: {
                    Label(
                        model.status == .paused ? "Resume" : "Pause",
                        systemImage: model.status == .paused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.status == .stopping)

                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(model.status == .stopping)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Recording couldn’t start", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Menu("Open Privacy Settings") {
                ForEach(PrivacyPane.allCases) { pane in
                    Button(pane.rawValue) { model.openPrivacySettings(pane) }
                }
            }
            .font(.caption)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var footer: some View {
        HStack {
            if showsOpenWindowButton {
                Button("Open Window") {
                    openWindow(id: "recorder")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderless)
                Divider()
                    .frame(height: 12)
            }
            Button("Show Recordings") { model.revealRecordings() }
                .buttonStyle(.borderless)
            Menu("Replay") {
                Button("Replay Last Recording") {
                    if replayModel.loadLatest(preferredURL: model.lastRecordingURL) {
                        openWindow(id: "replay")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
                Button("Open Recording…") {
                    if replayModel.chooseAndLoadRecording() {
                        openWindow(id: "replay")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch model.status {
        case .recording: return .red
        case .paused: return .orange
        case .starting, .stopping: return .blue
        case .idle: return .secondary
        }
    }

    private var formattedDuration: String {
        let seconds = model.elapsedNanoseconds / 1_000_000_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
