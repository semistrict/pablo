import PabloCore
import SwiftUI
import WebKit

struct RRWebPlayerWebView: NSViewRepresentable {
    let recording: PabloRRWebRecording
    @ObservedObject var model: ReplayModel

    @MainActor
    final class Coordinator: NSObject, RRWebPlaybackControlling {
        weak var webView: WKWebView?
        weak var model: ReplayModel?
        var temporaryDirectory: URL?
        private var timer: Timer?
        private var ready = false
        private var desiredTime: TimeInterval = 0
        private var desiredRate: Float = 1
        private var desiredPlaying = false

        func startPolling() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(
                timeInterval: 0.1,
                target: self,
                selector: #selector(poll),
                userInfo: nil,
                repeats: true
            )
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            webView = nil
        }

        func play() {
            desiredPlaying = true
            run("window.pabloPlayer?.play()")
        }

        func pause() {
            desiredPlaying = false
            run("window.pabloPlayer?.pause()")
        }

        func seek(to seconds: TimeInterval) {
            desiredTime = max(0, seconds)
            run("window.pabloPlayer?.goto(\(desiredTime * 1000), false)")
        }

        func setPlaybackRate(_ rate: Float) {
            desiredRate = rate
            run("window.pabloPlayer?.setSpeed(\(rate))")
        }

        func observedPlayback() async throws -> RRWebObservedPlayback {
            guard ready, let webView else { throw RecordingError.capture("The web renderer is not ready.") }
            let value = try await webView.evaluateJavaScript(
                "({time: (window.pabloTime || 0) / 1000, playing: !!window.pabloPlaying, error: window.pabloPlayerError || null})")
            guard let state = value as? [String: Any], let time = (state["time"] as? NSNumber)?.doubleValue else {
                throw RecordingError.capture("The web renderer did not return playback state.")
            }
            if let error = state["error"] as? String { throw RecordingError.capture(error) }
            return RRWebObservedPlayback(time: time, playing: state["playing"] as? Bool ?? false)
        }

        func snapshot(maxPixelDimension: Int) async throws -> NSImage {
            guard ready, let webView, let model, !model.isPlaying else {
                throw RecordingError.capture("Pause and settle the web renderer before exporting a frame.")
            }
            let before = try await observedPlayback()
            guard !before.playing else { throw RecordingError.capture("The web renderer is still playing.") }
            let value = try await webView.evaluateJavaScript("(() => { const r = document.querySelector('iframe')?.getBoundingClientRect(); return r ? {x:r.x,y:r.y,width:r.width,height:r.height} : null; })()")
            guard let rect = value as? [String: Double], let x = rect["x"], let y = rect["y"],
                  let width = rect["width"], let height = rect["height"], width > 0, height > 0 else {
                throw RecordingError.capture("The recorded web viewport is unavailable.")
            }
            let region = CGRect(x: x, y: y, width: width, height: height).intersection(webView.bounds)
            guard !region.isNull, !region.isEmpty else { throw RecordingError.capture("The recorded web viewport is not visible.") }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = region
            configuration.snapshotWidth = NSNumber(value: min(Double(maxPixelDimension), Double(maxPixelDimension) * region.width / region.height))
            let snapshot = try await webView.takeSnapshot(configuration: configuration)
            let after = try await observedPlayback()
            guard !after.playing, abs(after.time - before.time) < 0.001 else { throw CancellationError() }
            return snapshot
        }

        @objc private func poll() {
            webView?.evaluateJavaScript(
                "({ready: !!window.pabloPlayer, time: (window.pabloTime || 0) / 1000, playing: !!window.pabloPlaying, error: window.pabloPlayerError || null})"
            ) { [weak self] value, _ in
                Task { @MainActor in
                    guard let self, let state = value as? [String: Any] else { return }
                    let isReady = state["ready"] as? Bool ?? false
                    self.model?.updateWebRenderer(ready: isReady, error: state["error"] as? String)
                    if isReady && !self.ready {
                        self.ready = true
                        self.run("window.pabloPlayer.setSpeed(\(self.desiredRate)); window.pabloPlayer.goto(\(self.desiredTime * 1000), \(self.desiredPlaying ? "true" : "false"))")
                        return
                    }
                    let time = (state["time"] as? NSNumber)?.doubleValue ?? 0
                    let playing = state["playing"] as? Bool ?? false
                    if self.ready { self.model?.updateWebPlayback(time: time, playing: playing) }
                }
            }
        }

        private func run(_ script: String) {
            guard ready else { return }
            webView?.evaluateJavaScript(script) { [weak self] _, error in
                if let error {
                    Task { @MainActor in self?.model?.updateWebRenderer(ready: false, error: error.localizedDescription) }
                }
            }
        }

        deinit {
            timer?.invalidate()
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let coordinator = context.coordinator
        coordinator.webView = webView
        coordinator.model = model
        coordinator.startPolling()
        model.attachWebPlaybackController(coordinator)
        webView.setValue(false, forKey: "drawsBackground")
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PabloRRWebOfflinePlayback",
            encodedContentRuleList: Self.offlineRules
        ) { ruleList, error in
            DispatchQueue.main.async {
                guard let ruleList else {
                    let detail = error?.localizedDescription ?? "unknown content-rule error"
                    coordinator.model?.updateWebRenderer(ready: false, error: detail)
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

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.model?.detachWebPlaybackController(coordinator)
        coordinator.stop()
    }

    private func load(_ recording: PabloRRWebRecording, into webView: WKWebView, coordinator: Coordinator) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Pablo-RRWeb-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            coordinator.temporaryDirectory = directory

            let resources = try PabloPackageResources.bundle(
                named: "Pablo_PabloApp", developmentBundle: .module
            )
            guard let script = resources.url(
                forResource: "player",
                withExtension: "js",
                subdirectory: "RRWebPlayer"
            ), let stylesheet = resources.url(
                forResource: "player",
                withExtension: "css",
                subdirectory: "RRWebPlayer"
            ) else {
                throw RecordingError.capture("The rrweb player assets are missing from Pablo.")
            }
            try FileManager.default.copyItem(at: script, to: directory.appendingPathComponent("player.js"))
            try FileManager.default.copyItem(at: stylesheet, to: directory.appendingPathComponent("player.css"))
            let events = try Data(contentsOf: recording.eventsURL)
            try Data(Self.playerHTML(events: events).utf8).write(
                to: directory.appendingPathComponent("index.html"),
                options: .atomic
            )
            webView.loadFileURL(
                directory.appendingPathComponent("index.html"),
                allowingReadAccessTo: directory
            )
        } catch {
            coordinator.model?.updateWebRenderer(ready: false, error: error.localizedDescription)
            webView.loadHTMLString(
                "<html><body><p>Could not load rrweb recording: \(Self.htmlEscaped(error.localizedDescription))</p></body></html>",
                baseURL: nil
            )
        }
    }

    static func playerHTML(events: Data) -> String {
        let encodedEvents = events.base64EncodedString()
        return """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'self' data: blob:; connect-src 'self'; img-src data: blob:; media-src data: blob:; font-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'">
      <link rel="stylesheet" href="player.css">
      <style>
        html, body, #player { margin: 0; width: 100%; height: 100%; background: #151515; }
        body { display: grid; place-items: center; overflow: hidden; }
      </style>
    </head>
    <body>
      <div id="player"></div>
      <script src="player.js"></script>
      <script>
        try {
            const bytes = Uint8Array.from(atob("\(encodedEvents)"), (character) => character.charCodeAt(0));
            const events = JSON.parse(new TextDecoder().decode(bytes));
            if (!Array.isArray(events) || events.length === 0) {
              throw new Error("This recording contains no replayable events.");
            }
            const player = new PabloRRWebPlayer({
              target: document.getElementById("player"),
              props: {
                events,
                width: Math.max(320, window.innerWidth),
                height: Math.max(240, window.innerHeight),
                autoPlay: false,
                showController: false,
                skipInactive: true,
                speedOption: [0.5, 1, 2, 4, 8],
              },
            });
            window.pabloPlayer = player;
            window.pabloTime = 0;
            window.pabloPlaying = false;
            player.addEventListener("ui-update-current-time", ({ payload: time }) => { window.pabloTime = time; });
            player.addEventListener("ui-update-player-state", ({ payload: state }) => {
              window.pabloPlaying = state === "playing";
            });
            player.getReplayer().on("finish", () => { window.pabloPlaying = false; });
            window.addEventListener("resize", () => player.$set({
              width: Math.max(320, window.innerWidth),
              height: Math.max(240, window.innerHeight),
            }));
        } catch (error) {
          window.pabloPlayerError = String(error);
          document.getElementById("player").textContent = `Could not load recording: ${error}`;
        }
      </script>
    </body>
    </html>
    """
    }

    private static let offlineRules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
