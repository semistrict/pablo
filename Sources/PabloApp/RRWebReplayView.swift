import AppKit
import PabloCore
import SwiftUI
import WebKit

@MainActor
final class RRWebReplayModel: ObservableObject {
    @Published private(set) var recordings: [PabloRRWebRecording] = []
    @Published var selectedRecordingID: UUID?
    @Published private(set) var errorMessage: String?

    var selectedRecording: PabloRRWebRecording? {
        guard let selectedRecordingID else { return recordings.first }
        return recordings.first { $0.manifest.recordingID == selectedRecordingID }
    }

    func load(
        preferredURL: URL? = nil,
        directory: URL = PabloRecordingStorage.localRecordingsDirectory
    ) {
        do {
            recordings = try PabloRRWebRecordingStorage.recordings(directory: directory)
            if let preferredURL {
                let preferred = try PabloRRWebRecordingStorage.load(preferredURL)
                if !recordings.contains(where: { $0.manifest.recordingID == preferred.manifest.recordingID }) {
                    recordings.insert(preferred, at: 0)
                }
                selectedRecordingID = preferred.manifest.recordingID
            } else {
                selectedRecordingID = recordings.first?.manifest.recordingID
            }
            errorMessage = recordings.isEmpty ? "No Safari web recordings were found." : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RRWebReplayView: View {
    @ObservedObject var model: RRWebReplayModel
    @ObservedObject var recorderModel: RecorderModel
    let openRecordings: @MainActor () -> Void
    private let statusTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Safari Web Recordings")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                List(selection: $model.selectedRecordingID) {
                    ForEach(model.recordings, id: \.manifest.recordingID) { recording in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recording.manifest.tab.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Text(recording.manifest.startedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(recording.manifest.eventCount) rrweb events · \(recording.manifest.state.rawValue)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(recording.manifest.recordingID)
                    }
                }
                Button("Open Recordings…", action: openRecordings)
                    .padding(12)
            }
            .frame(minWidth: 230, idealWidth: 270)

            Group {
                VStack(spacing: 0) {
                    recordingControls
                    Divider()
                    if let recording = model.selectedRecording {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recording.manifest.tab.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(recording.manifest.tab.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if recording.manifest.inputsMasked {
                                Label("Inputs masked", systemImage: "eye.slash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        Divider()
                        RRWebPlayerWebView(recording: recording)
                            .id(recording.manifest.recordingID)
                    } else if let error = model.errorMessage {
                        ContentUnavailableView(
                            "No Web Recording",
                            systemImage: "safari",
                            description: Text(error)
                        )
                    }
                }
            }
            .frame(minWidth: 640)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await recorderModel.refreshSafariTabs() }
        .onReceive(statusTimer) { _ in recorderModel.refreshRRWebStatusIfNeeded() }
    }

    @ViewBuilder
    private var recordingControls: some View {
        HStack(spacing: 10) {
            if let active = recorderModel.activeRRWebRecording {
                Label(
                    "\(active.manifest.state.rawValue.capitalized) · \(recorderModel.rrwebEventCount) events · inputs masked",
                    systemImage: "record.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer()
                Button(active.manifest.state == .paused ? "Resume" : "Pause") {
                    Task {
                        if active.manifest.state == .paused {
                            await recorderModel.resumeRRWebRecording()
                        } else {
                            await recorderModel.pauseRRWebRecording()
                        }
                    }
                }
                Button("Stop", role: .destructive) {
                    Task {
                        await recorderModel.stopRRWebRecording()
                        model.load(preferredURL: recorderModel.lastRecordingURL)
                    }
                }
            } else {
                Text("Record another unlocked Safari tab")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("Start Recording") {
                    if recorderModel.safariTabs.isEmpty {
                        Text("No unlocked active tabs")
                    } else {
                        ForEach(recorderModel.safariTabs) { tab in
                            Button(tab.title) {
                                Task { await recorderModel.startRRWebRecording(tab: tab) }
                            }
                        }
                    }
                }
                Button("Refresh Tabs") {
                    Task { await recorderModel.refreshSafariTabs() }
                }
            }
        }
        .padding(10)
    }
}

private struct RRWebPlayerWebView: NSViewRepresentable {
    let recording: PabloRRWebRecording

    final class Coordinator {
        var temporaryDirectory: URL?
        deinit {
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let coordinator = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PabloRRWebOfflinePlayback",
            encodedContentRuleList: Self.offlineRules
        ) { ruleList, error in
            DispatchQueue.main.async {
                guard let ruleList else {
                    let detail = error?.localizedDescription ?? "unknown content-rule error"
                    webView.loadHTMLString(
                        "<html><body><p>Could not secure offline playback: \(Self.htmlEscaped(detail))</p></body></html>",
                        baseURL: nil
                    )
                    return
                }
                webView.configuration.userContentController.add(ruleList)
                load(recording, into: webView, coordinator: coordinator)
            }
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    private func load(_ recording: PabloRRWebRecording, into webView: WKWebView, coordinator: Coordinator) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Pablo-RRWeb-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            coordinator.temporaryDirectory = directory

            guard let script = Bundle.module.url(
                forResource: "player",
                withExtension: "js",
                subdirectory: "RRWebPlayer"
            ), let stylesheet = Bundle.module.url(
                forResource: "player",
                withExtension: "css",
                subdirectory: "RRWebPlayer"
            ) else {
                throw RecordingError.capture("The rrweb player assets are missing from Pablo.")
            }
            try FileManager.default.copyItem(at: script, to: directory.appendingPathComponent("player.js"))
            try FileManager.default.copyItem(at: stylesheet, to: directory.appendingPathComponent("player.css"))
            try FileManager.default.copyItem(
                at: recording.eventsURL,
                to: directory.appendingPathComponent("events.json")
            )
            try Data(Self.playerHTML.utf8).write(
                to: directory.appendingPathComponent("index.html"),
                options: .atomic
            )
            webView.loadFileURL(
                directory.appendingPathComponent("index.html"),
                allowingReadAccessTo: directory
            )
        } catch {
            webView.loadHTMLString(
                "<html><body><p>Could not load rrweb recording: \(Self.htmlEscaped(error.localizedDescription))</p></body></html>",
                baseURL: nil
            )
        }
    }

    private static let playerHTML = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'self' data: blob:; connect-src 'self'; img-src data: blob:; media-src data: blob:; font-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'">
      <link rel="stylesheet" href="player.css">
      <style>
        html, body, #player { margin: 0; min-height: 100%; background: #151515; }
        body { display: grid; place-items: center; overflow: auto; }
        .rr-player { margin: 16px; }
      </style>
    </head>
    <body>
      <div id="player"></div>
      <script src="player.js"></script>
      <script>
        fetch("events.json")
          .then((response) => {
            if (!response.ok) throw new Error(`events.json returned ${response.status}`);
            return response.json();
          })
          .then((events) => {
            if (!Array.isArray(events) || events.length === 0) {
              throw new Error("This recording contains no replayable events.");
            }
            const player = new PabloRRWebPlayer({
              target: document.getElementById("player"),
              props: {
                events,
                width: Math.max(720, window.innerWidth - 40),
                height: Math.max(480, window.innerHeight - 120),
                autoPlay: false,
                showController: true,
                skipInactive: true,
                speedOption: [0.5, 1, 2, 4, 8],
              },
            });
            window.addEventListener("resize", () => player.$set({
              width: Math.max(720, window.innerWidth - 40),
              height: Math.max(480, window.innerHeight - 120),
            }));
          })
          .catch((error) => {
            document.getElementById("player").textContent = `Could not load recording: ${error}`;
          });
      </script>
    </body>
    </html>
    """

    private static let offlineRules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
