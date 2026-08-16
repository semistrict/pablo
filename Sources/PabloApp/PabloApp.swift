import AppKit
import PabloCore
import Security
import SwiftUI
import UniformTypeIdentifiers

private final class PabloReviewWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           event.clickCount == 2,
           event.window === self,
           event.locationInWindow.y >= contentLayoutRect.maxY,
           !hasInteractiveControl(at: event.locationInWindow) {
            performZoom(nil)
            return
        }
        super.sendEvent(event)
    }

    private func hasInteractiveControl(at point: NSPoint) -> Bool {
        var view = contentView?.superview?.hitTest(point)
        while let current = view {
            if current is NSButton || current is NSSegmentedControl ||
                current is NSSlider || current is NSPopUpButton {
                return true
            }
            view = current.superview
        }
        return false
    }
}

@main
struct PabloMenuBarApp: App {
    @NSApplicationDelegateAdaptor(PabloApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = RecorderModel.shared

    var body: some Scene {
        MenuBarExtra {
            StatusPanel(
                model: model,
                showReview: { preferredURL in
                    applicationDelegate.showReviewWindow(preferredURL: preferredURL)
                }
            )
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(model.statusTitle)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Arrange Side by Side") {
                    applicationDelegate.arrangeReviewWindowsSideBySide()
                }
            }
        }
    }
}

@MainActor
final class PabloApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var recorderWindowController: NSWindowController?
    private var reviewWindowControllers: [NSWindowController] = []
    private var reviewWindowRecency: [ObjectIdentifier] = []
    private var pendingRecordingURLs: [URL] = []
    private var didFinishLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        do {
            try PabloRecordingStorage.migrateLegacyRecordings()
        } catch {
            RecorderModel.shared.errorMessage =
                "Could not move existing recordings to Documents: \(error.localizedDescription)"
        }
        RecorderModel.shared.recordingDidFinish = { [weak self] recordingURL in
            self?.showReviewWindow(preferredURL: recordingURL)
        }
        showRecorderWindow()
        let recordingURLs = pendingRecordingURLs
        pendingRecordingURLs.removeAll()
        for recordingURL in recordingURLs {
            showReviewWindow(preferredURL: recordingURL)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let recordingURLs = urls
            .filter {
                $0.pathExtension.caseInsensitiveCompare("pablo") == .orderedSame ||
                    $0.pathExtension.caseInsensitiveCompare(PabloRRWebRecordingStorage.packageExtension) == .orderedSame
            }
        guard !recordingURLs.isEmpty else { return }
        if didFinishLaunching {
            for recordingURL in recordingURLs {
                showReviewWindow(preferredURL: recordingURL)
            }
        } else {
            pendingRecordingURLs.append(contentsOf: recordingURLs)
        }
    }

    func showReviewWindow(preferredURL: URL? = nil) {
        if preferredURL?.pathExtension.caseInsensitiveCompare(
            PabloRRWebRecordingStorage.packageExtension
        ) == .orderedSame {
            showRRWebReviewWindow(preferredURL: preferredURL)
            return
        }
        let replayModel = ReplayModel()
        _ = replayModel.loadLatest(preferredURL: preferredURL)
        let content = NSHostingController(rootView: ReplayView(
            model: replayModel,
            openRecordings: { [weak self] in self?.chooseRecordingsAndOpen() }
        ))
        let window = PabloReviewWindow(contentViewController: content)
        let recordingURL = replayModel.recording?.packageURL
        window.title = recordingURL?.deletingPathExtension().lastPathComponent ?? "Pablo"
        window.representedURL = recordingURL
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = PabloReviewWindowLayout.preferredMinimumSize
        window.setContentSize(NSSize(width: 1_180, height: 720))
        window.isExcludedFromWindowsMenu = false
        if reviewWindowControllers.isEmpty {
            window.setFrameAutosaveName("PabloReviewWindow")
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        positionNewReviewWindow(window)
        let controller = NSWindowController(window: window)
        reviewWindowControllers.append(controller)
        noteReviewWindowActivated(window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.setWindowsNeedUpdate(true)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showRRWebReviewWindow(preferredURL: URL?) {
        let replayModel = RRWebReplayModel()
        replayModel.load(preferredURL: preferredURL)
        let content = NSHostingController(rootView: RRWebReplayView(
            model: replayModel,
            recorderModel: RecorderModel.shared,
            openRecordings: { [weak self] in self?.chooseRecordingsAndOpen() }
        ))
        let window = PabloReviewWindow(contentViewController: content)
        window.title = preferredURL?.deletingPathExtension().lastPathComponent ?? "Safari Web Recordings"
        window.representedURL = preferredURL
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1_180, height: 760))
        window.isExcludedFromWindowsMenu = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        positionNewReviewWindow(window)
        let controller = NSWindowController(window: window)
        reviewWindowControllers.append(controller)
        noteReviewWindowActivated(window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.setWindowsNeedUpdate(true)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showRecorderWindow() {
        if let window = recorderWindowController?.window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let content = NSHostingController(rootView: RecorderWindowView(
            model: RecorderModel.shared,
            showReview: { [weak self] preferredURL in
                self?.showReviewWindow(preferredURL: preferredURL)
            },
            openRecordings: { [weak self] in self?.chooseRecordingsAndOpen() }
        ))
        let window = PabloReviewWindow(contentViewController: content)
        window.title = "Pablo Recorder"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 640, height: 520)
        window.setContentSize(NSSize(width: 760, height: 620))
        window.setFrameAutosaveName("PabloRecorderWindow")
        window.isExcludedFromWindowsMenu = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        recorderWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.setWindowsNeedUpdate(true)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        noteReviewWindowActivated(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if recorderWindowController?.window === window {
            recorderWindowController = nil
            NSApplication.shared.setWindowsNeedUpdate(true)
            return
        }
        let identifier = ObjectIdentifier(window)
        reviewWindowRecency.removeAll { $0 == identifier }
        reviewWindowControllers.removeAll { $0.window === window }
        NSApplication.shared.setWindowsNeedUpdate(true)
    }

    func arrangeReviewWindowsSideBySide() {
        let windows = reviewWindowControllers.compactMap(\.window).filter {
            $0.isVisible && !$0.isMiniaturized
        }
        guard !windows.isEmpty else { return }

        let currentWindow = mostRecentReviewWindow.flatMap { candidate in
            windows.first(where: { $0 === candidate })
        } ?? windows[0]

        var windowsByScreen: [ObjectIdentifier: (screen: NSScreen, windows: [NSWindow])] = [:]
        for window in windows {
            guard let screen = window.screen ?? currentWindow.screen ?? NSScreen.main else {
                continue
            }
            let identifier = ObjectIdentifier(screen)
            if windowsByScreen[identifier] == nil {
                windowsByScreen[identifier] = (screen, [])
            }
            windowsByScreen[identifier]?.windows.append(window)
        }

        for group in windowsByScreen.values where group.windows.count > 1 {
            let layout = PabloReviewWindowLayout.tiled(
                windowCount: group.windows.count,
                in: group.screen.visibleFrame
            )
            for (window, frame) in zip(group.windows, layout.frames) {
                window.setFrame(frame, display: true, animate: true)
            }
        }

        currentWindow.makeKeyAndOrderFront(nil)
        noteReviewWindowActivated(currentWindow)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func chooseRecordingsAndOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open Pablo Recordings"
        panel.prompt = "Review"
        panel.directoryURL = ReplayModel.recordingsDirectory
        panel.allowedContentTypes = [
            UTType(exportedAs: "com.ramon.pablo.recording", conformingTo: .package),
            UTType(exportedAs: "com.ramon.pablo.web-recording", conformingTo: .package),
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for recordingURL in panel.urls {
                let pathExtension = recordingURL.pathExtension
                guard pathExtension.caseInsensitiveCompare("pablo") == .orderedSame ||
                        pathExtension.caseInsensitiveCompare(
                            PabloRRWebRecordingStorage.packageExtension
                        ) == .orderedSame else { continue }
                self?.showReviewWindow(preferredURL: recordingURL)
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showRecorderWindow()
        return true
    }

    private var mostRecentReviewWindow: NSWindow? {
        for identifier in reviewWindowRecency.reversed() {
            if let window = reviewWindowControllers.lazy.compactMap(\.window).first(where: {
                ObjectIdentifier($0) == identifier
            }) {
                return window
            }
        }
        return reviewWindowControllers.reversed().compactMap(\.window).first
    }

    private func noteReviewWindowActivated(_ window: NSWindow) {
        guard reviewWindowControllers.contains(where: { $0.window === window }) else { return }
        let identifier = ObjectIdentifier(window)
        reviewWindowRecency.removeAll { $0 == identifier }
        reviewWindowRecency.append(identifier)
    }

    private func positionNewReviewWindow(_ window: NSWindow) {
        guard let previousWindow = mostRecentReviewWindow else {
            window.center()
            return
        }

        let step: CGFloat = 28
        let screenFrame = (previousWindow.screen ?? NSScreen.main)?.visibleFrame
        var frame = window.frame
        frame.origin = NSPoint(
            x: previousWindow.frame.minX + step,
            y: previousWindow.frame.minY - step
        )

        if let screenFrame,
           frame.maxX > screenFrame.maxX - step || frame.minY < screenFrame.minY + step {
            frame.origin = NSPoint(
                x: screenFrame.minX + step,
                y: screenFrame.maxY - frame.height - step
            )
        }
        window.setFrame(frame, display: false)
    }
}

@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()

    private struct ControlCaller {
        let displayName: String
        let applicationIdentifier: String?
        let developerName: String?
        let developerTeamIdentifier: String?
        let cacheIdentity: String?

        var automationCaller: PabloAutomationCaller {
            PabloAutomationCaller(
                displayName: displayName,
                applicationIdentifier: applicationIdentifier,
                developerName: developerName,
                developerTeamIdentifier: developerTeamIdentifier,
                verified: cacheIdentity != nil
            )
        }
    }

    private struct CodeSigningIdentity {
        let teamIdentifier: String
        let identifier: String
        let developerName: String?
    }

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
    @Published var safariTabs: [PabloSafariTab] = []
    @Published var rrwebRecordings: [PabloRRWebRecording] = []
    @Published var activeRRWebRecording: PabloRRWebRecording?
    @Published var rrwebEventCount = 0
    @Published var refreshingSafariTabs = false

    var recordingDidFinish: ((URL) -> Void)?

    private var session: RecordingSession?
    private var automaticStopTask: Task<Void, Never>?
    private var rrwebStatusRefreshInFlight = false
    private var lastRRWebStatusRefresh = Date.distantPast
    private var rrwebStatusFailureCount = 0
    private let dailyApprovalStore = PabloDailyApprovalStore()
    private let liveInspectionManager = PabloLiveInspectionManager()
    private lazy var liveActionController = PabloLiveActionController(
        inspectionManager: liveInspectionManager
    )
    private let safariDOMBridge = PabloSafariDOMBridge()
    private lazy var controlServer = PabloControlServer { [weak self] request, peer in
        guard let self else {
            return PabloControlResponse(id: request.id, error: "Pablo is shutting down.")
        }
        return await self.handleControlRequest(request, from: peer)
    }

    init() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.startControlServer()
            await self.recoverRRWebRecordingIfNeeded()
        }
    }

    var statusTitle: String {
        if status == .idle, let rrwebState = activeRRWebRecording?.manifest.state {
            switch rrwebState {
            case .recording: return "Recording Safari"
            case .paused: return "Safari Paused"
            case .complete, .interrupted, .failed: break
            }
        }
        switch status {
        case .idle: return "Ready"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Finishing…"
        }
    }

    var menuBarSymbol: String {
        if status == .idle, let rrwebState = activeRRWebRecording?.manifest.state {
            switch rrwebState {
            case .recording: return "record.circle.fill"
            case .paused: return "pause.circle.fill"
            case .complete, .interrupted, .failed: break
            }
        }
        switch status {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .starting, .stopping: return "circle.dotted"
        case .idle: return "record.circle"
        }
    }

    var canStartApplication: Bool { status == .idle && selectedPID != nil }
    var canStartScreen: Bool { status == .idle }
    var isActive: Bool { status == .recording || status == .paused }
    var activeScopeName: String? { session?.scopeName }
    var rrwebIsActive: Bool {
        guard let state = activeRRWebRecording?.manifest.state else { return false }
        return state == .recording || state == .paused
    }

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

    func refreshSafariTabs() async {
        refreshingSafariTabs = true
        defer { refreshingSafariTabs = false }
        do {
            async let tabs = safariDOMBridge.listTabs()
            async let recordings = Task.detached { try PabloRRWebRecordingStorage.recordings() }.value
            safariTabs = try await tabs
            rrwebRecordings = try await recordings
        } catch {
            safariTabs = []
            rrwebRecordings = (try? PabloRRWebRecordingStorage.recordings()) ?? []
            errorMessage = error.localizedDescription
        }
    }

    func startRRWebRecording(tab: PabloSafariTab) async {
        guard !rrwebIsActive else {
            errorMessage = "Stop the current rrweb recording before starting another."
            return
        }
        errorMessage = nil
        let recordingID = UUID()
        do {
            try safariDOMBridge.prepareSpool(recordingID: recordingID)
            let recording = try PabloRRWebRecordingStorage.create(recordingID: recordingID, tab: tab)
            do {
                _ = try await safariDOMBridge.perform(PabloSafariDOMRequest(
                    kind: .startRRWebRecording,
                    tabID: tab.id,
                    recordingID: recordingID
                ))
            } catch {
                try? FileManager.default.removeItem(at: recording.packageURL)
                throw error
            }
            activeRRWebRecording = recording
            rrwebEventCount = 0
            rrwebStatusFailureCount = 0
            rrwebRecordings = try PabloRRWebRecordingStorage.recordings()
        } catch {
            activeRRWebRecording = nil
            try? safariDOMBridge.removeSpool(recordingID: recordingID)
            errorMessage = error.localizedDescription
        }
    }

    func refreshRRWebStatusIfNeeded(now: Date = Date()) {
        guard rrwebIsActive, !rrwebStatusRefreshInFlight,
              now.timeIntervalSince(lastRRWebStatusRefresh) >= 1 else { return }
        rrwebStatusRefreshInFlight = true
        lastRRWebStatusRefresh = now
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.rrwebStatusRefreshInFlight = false }
            await self.refreshActiveRRWebStatus(reportErrors: false)
        }
    }

    func pauseRRWebRecording() async {
        guard let recording = activeRRWebRecording,
              recording.manifest.state == .recording else { return }
        do {
            let output = try await safariDOMBridge.perform(PabloSafariDOMRequest(
                kind: .pauseRRWebRecording,
                tabID: recording.manifest.tab.id,
                recordingID: recording.manifest.recordingID
            ))
            rrwebEventCount = rrwebEventCount(from: output) ?? rrwebEventCount
            activeRRWebRecording = try PabloRRWebRecordingStorage.updateState(
                .paused,
                packageURL: recording.packageURL
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resumeRRWebRecording() async {
        guard let recording = activeRRWebRecording,
              recording.manifest.state == .paused else { return }
        do {
            let output = try await safariDOMBridge.perform(PabloSafariDOMRequest(
                kind: .resumeRRWebRecording,
                tabID: recording.manifest.tab.id,
                recordingID: recording.manifest.recordingID
            ))
            rrwebEventCount = rrwebEventCount(from: output) ?? rrwebEventCount
            activeRRWebRecording = try PabloRRWebRecordingStorage.updateState(
                .recording,
                packageURL: recording.packageURL
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRRWebRecording() async {
        guard let recording = activeRRWebRecording else { return }
        var stopError: Error?
        var finalizedSuccessfully = false
        do {
            let output = try await safariDOMBridge.perform(PabloSafariDOMRequest(
                kind: .stopRRWebRecording,
                tabID: recording.manifest.tab.id,
                recordingID: recording.manifest.recordingID
            ))
            rrwebEventCount = rrwebEventCount(from: output) ?? rrwebEventCount
        } catch {
            stopError = error
        }

        do {
            let extensionError = (try? safariDOMBridge.recordingError(
                recordingID: recording.manifest.recordingID
            )) ?? recording.manifest.error
            let batches: [Data]
            do {
                batches = try safariDOMBridge.eventBatches(
                    recordingID: recording.manifest.recordingID
                )
            } catch {
                batches = []
                stopError = stopError ?? error
            }
            let finalized = try PabloRRWebRecordingStorage.finalize(
                packageURL: recording.packageURL,
                batches: batches,
                state: stopError == nil && extensionError == nil ? .complete : .interrupted,
                error: extensionError ?? stopError?.localizedDescription
            )
            activeRRWebRecording = nil
            rrwebStatusFailureCount = 0
            rrwebEventCount = finalized.manifest.eventCount
            lastRecordingURL = finalized.packageURL
            rrwebRecordings = try PabloRRWebRecordingStorage.recordings()
            recordingDidFinish?(finalized.packageURL)
            finalizedSuccessfully = true
        } catch {
            errorMessage = error.localizedDescription
        }
        if finalizedSuccessfully {
            try? safariDOMBridge.removeSpool(recordingID: recording.manifest.recordingID)
        }
        if let stopError { errorMessage = stopError.localizedDescription }
    }

    private func refreshActiveRRWebStatus(reportErrors: Bool) async {
        guard let recording = activeRRWebRecording else { return }
        do {
            let output = try await safariDOMBridge.perform(PabloSafariDOMRequest(
                kind: .rrwebRecordingStatus,
                tabID: recording.manifest.tab.id,
                recordingID: recording.manifest.recordingID
            ))
            rrwebEventCount = rrwebEventCount(from: output) ?? rrwebEventCount
            rrwebStatusFailureCount = 0
            if let bridgeError = rrwebError(from: output) {
                errorMessage = bridgeError
                activeRRWebRecording = try PabloRRWebRecordingStorage.updateState(
                    recording.manifest.state,
                    packageURL: recording.packageURL,
                    error: bridgeError
                )
            }
        } catch {
            rrwebStatusFailureCount += 1
            let storedError = try? safariDOMBridge.recordingError(
                recordingID: recording.manifest.recordingID
            )
            if storedError != nil || rrwebStatusFailureCount >= 3 {
                do {
                    let reason = storedError ?? "The Safari recorder stopped responding: \(error.localizedDescription)"
                    let finalized = try finalizeInterruptedRRWebRecording(recording, reason: reason)
                    activeRRWebRecording = nil
                    rrwebStatusFailureCount = 0
                    rrwebEventCount = finalized.manifest.eventCount
                    lastRecordingURL = finalized.packageURL
                    rrwebRecordings = try PabloRRWebRecordingStorage.recordings()
                    errorMessage = reason
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else if reportErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recoverRRWebRecordingIfNeeded() async {
        do {
            let candidates = try PabloRRWebRecordingStorage.recordings().filter {
                $0.manifest.state == .recording || $0.manifest.state == .paused
            }
            guard let newest = candidates.first else {
                rrwebRecordings = try PabloRRWebRecordingStorage.recordings()
                return
            }
            for stale in candidates.dropFirst() {
                _ = try finalizeInterruptedRRWebRecording(
                    stale,
                    reason: "Pablo restarted while a newer Safari recording was active."
                )
            }
            activeRRWebRecording = newest
            rrwebStatusFailureCount = 0
            let output = try await safariDOMBridge.perform(PabloSafariDOMRequest(
                kind: .rrwebRecordingStatus,
                tabID: newest.manifest.tab.id,
                recordingID: newest.manifest.recordingID
            ))
            rrwebEventCount = rrwebEventCount(from: output) ?? 0
            rrwebRecordings = try PabloRRWebRecordingStorage.recordings()
        } catch {
            if let recording = activeRRWebRecording {
                do {
                    let finalized = try finalizeInterruptedRRWebRecording(
                        recording,
                        reason: "Pablo could not reconnect to the Safari recorder: \(error.localizedDescription)"
                    )
                    activeRRWebRecording = nil
                    rrwebStatusFailureCount = 0
                    rrwebEventCount = finalized.manifest.eventCount
                    rrwebRecordings = try PabloRRWebRecordingStorage.recordings()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func finalizeInterruptedRRWebRecording(
        _ recording: PabloRRWebRecording,
        reason: String
    ) throws -> PabloRRWebRecording {
        let extensionError = try? safariDOMBridge.recordingError(
            recordingID: recording.manifest.recordingID
        )
        let finalized = try PabloRRWebRecordingStorage.finalize(
            packageURL: recording.packageURL,
            batches: (try? safariDOMBridge.eventBatches(
                recordingID: recording.manifest.recordingID
            )) ?? [],
            state: .interrupted,
            error: extensionError ?? reason
        )
        try? safariDOMBridge.removeSpool(recordingID: recording.manifest.recordingID)
        return finalized
    }

    private func rrwebEventCount(from output: PabloControlOutput) -> Int? {
        guard case .object(let object) = output,
              case .integer(let count)? = object["eventCount"] else { return nil }
        return Int(count)
    }

    private func rrwebError(from output: PabloControlOutput) -> String? {
        guard case .object(let object) = output,
              case .string(let error)? = object["error"],
              !error.isEmpty else { return nil }
        return error
    }

    private func rrwebStatusOutput() throws -> PabloControlOutput {
        let active = activeRRWebRecording.map { RRWebAPIRecording(recording: $0) }
        return try controlOutput(RRWebAPIStatus(active: active, eventCount: rrwebEventCount))
    }

    private func rrwebRecordingsOutput() throws -> PabloControlOutput {
        let recordings = try PabloRRWebRecordingStorage.recordings().map(RRWebAPIRecording.init)
        return try controlOutput(["recordings": recordings])
    }

    private func rrwebInspectOutput(_ request: PabloRRWebControlRequest) throws -> PabloControlOutput {
        guard request.tabID == nil else {
            throw RecordingError.usage("rrweb.inspect does not accept tabID.")
        }
        let selectorCount = [request.recordingPath != nil, request.recordingID != nil]
            .filter { $0 }.count
        guard selectorCount == 1 else {
            throw RecordingError.usage("rrweb.inspect requires exactly one recordingPath or recordingID.")
        }
        guard (1...10_000).contains(request.eventLimit) else {
            throw RecordingError.usage("eventLimit must be from 1 to 10000.")
        }
        let recording: PabloRRWebRecording
        if let path = request.recordingPath {
            recording = try PabloRRWebRecordingStorage.load(URL(fileURLWithPath: path))
        } else if let recordingID = request.recordingID,
                  let match = try PabloRRWebRecordingStorage.recordings().first(where: {
                      $0.manifest.recordingID == recordingID
                  }) {
            recording = match
        } else {
            throw RecordingError.usage("rrweb.inspect requires recordingPath or recordingID.")
        }
        var object: [String: PabloControlOutput] = [
            "recording": try controlOutput(RRWebAPIRecording(recording: recording)),
        ]
        if request.includeEvents {
            let decoded = try JSONDecoder().decode(
                [PabloControlOutput].self,
                from: Data(contentsOf: recording.eventsURL)
            )
            object["events"] = .array(Array(decoded.prefix(request.eventLimit)))
            object["eventsTruncated"] = .boolean(decoded.count > request.eventLimit)
        }
        return .object(object)
    }

    private func controlOutput<Value: Encodable>(_ value: Value) throws -> PabloControlOutput {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(PabloControlOutput.self, from: encoder.encode(value))
    }

    func startApplicationRecording(pid: pid_t? = nil) async {
        let pid = pid ?? selectedPID
        guard status == .idle, let pid else { return }
        errorMessage = nil
        status = .starting
        do {
            var options = RecordOptions()
            options.scope = .application
            options.pid = pid
            options.captureText = captureText
            try await beginRecording(options)
        } catch {
            session = nil
            status = .idle
            errorMessage = error.localizedDescription
        }
    }

    func startScreenRecording() async {
        guard canStartScreen else { return }
        errorMessage = nil
        status = .starting
        do {
            var options = RecordOptions()
            options.scope = .display
            options.captureText = captureText
            try await beginRecording(options)
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
        guard isActive, let activeSession = session else { return }
        automaticStopTask?.cancel()
        automaticStopTask = nil
        status = .stopping
        var completedRecordingURL: URL?
        do {
            try await activeSession.stop()
            completedRecordingURL = activeSession.packageURL
        } catch {
            errorMessage = error.localizedDescription
        }
        elapsedNanoseconds = activeSession.durationNs
        session = nil
        status = .idle
        refreshApplications()
        if let completedRecordingURL {
            recordingDidFinish?(completedRecordingURL)
        }
    }

    private func beginRecording(_ options: RecordOptions) async throws {
        guard status == .starting || status == .idle else {
            throw RecordingError.capture("Pablo is already recording.")
        }
        status = .starting
        let session = try RecordingSession(options: options)
        self.session = session
        do {
            try await session.start()
        } catch {
            self.session = nil
            status = .idle
            throw error
        }
        lastRecordingURL = session.packageURL
        elapsedNanoseconds = 0
        status = .recording
        if let duration = options.duration {
            automaticStopTask?.cancel()
            automaticStopTask = Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled, let self, self.session === session else { return }
                await self.stopRecording()
            }
        }
    }

    private func startControlServer() {
        do {
            try controlServer.start()
        } catch {
            errorMessage = "Local control service could not start: \(error.localizedDescription)"
        }
    }

    private func handleControlRequest(
        _ request: PabloControlRequest,
        from peer: PabloControlPeer
    ) async -> PabloControlResponse {
        let caller = controlCaller(for: peer)
        guard approveControlAccessIfNeeded(request, caller: caller) else {
            return PabloControlResponse(id: request.id, error: "The user denied this Pablo request.")
        }

        do {
            var annotation: RecordingAnnotation?
            var output: PabloControlOutput?
            switch request.method {
            case .startRecording:
                guard status == .idle else {
                    throw RecordingError.capture("Pablo is already recording or changing state.")
                }
                guard let remoteOptions = request.recordOptions else {
                    throw RecordingError.usage("The start command did not include recording options.")
                }
                let options = remoteOptions.recordOptions()
                try await beginRecording(options)
            case .pauseRecording:
                guard status == .recording else {
                    throw RecordingError.capture("There is no active recording to pause.")
                }
                togglePause()
            case .resumeRecording:
                guard status == .paused else {
                    throw RecordingError.capture("There is no paused recording to resume.")
                }
                togglePause()
            case .stopRecording:
                guard isActive else {
                    throw RecordingError.capture("There is no active recording to stop.")
                }
                await stopRecording()
            case .status:
                updateElapsedTime()
            case .addAnnotation:
                guard let annotationRequest = request.annotationRequest,
                      let draft = annotationRequest.draft else {
                    throw RecordingError.usage("The annotation command did not include markup.")
                }
                annotation = try RecordingAnnotationStore.add(
                    to: URL(fileURLWithPath: annotationRequest.recordingPath),
                    draft: draft,
                    author: annotationAuthor(for: caller)
                )
                NotificationCenter.default.post(
                    name: .pabloAnnotationsDidChange,
                    object: annotationRequest.recordingPath
                )
            case .resolveAnnotation:
                guard let annotationRequest = request.annotationRequest,
                      let reference = annotationRequest.reference else {
                    throw RecordingError.usage("The resolve command did not include an annotation reference.")
                }
                annotation = try RecordingAnnotationStore.resolve(
                    in: URL(fileURLWithPath: annotationRequest.recordingPath),
                    reference: reference,
                    author: annotationAuthor(for: caller)
                )
                NotificationCenter.default.post(
                    name: .pabloAnnotationsDidChange,
                    object: annotationRequest.recordingPath
                )
            case .inspectLive:
                guard let inspection = request.liveInspectionRequest else {
                    throw RecordingError.usage("The live inspection command did not include a request.")
                }
                output = try PabloControlOutput(json: liveInspectionManager.perform(inspection))
            case .actLive:
                guard let action = request.liveActionRequest else {
                    throw RecordingError.usage("The live action command did not include an action.")
                }
                let actionID = UUID()
                let recordingWasPaused = status == .paused
                try recordAutomationActionIfApplicable(
                    action,
                    actionID: actionID,
                    phase: .requested,
                    caller: caller,
                    recordingWasPaused: recordingWasPaused
                )
                do {
                    output = .string(try await liveActionController.perform(action))
                    try recordAutomationActionIfApplicable(
                        action,
                        actionID: actionID,
                        phase: .succeeded,
                        caller: caller,
                        recordingWasPaused: recordingWasPaused
                    )
                } catch {
                    try? recordAutomationActionIfApplicable(
                        action,
                        actionID: actionID,
                        phase: .failed,
                        caller: caller,
                        recordingWasPaused: recordingWasPaused
                    )
                    throw error
                }
            case .safariTabs:
                output = try controlOutput(["tabs": try await safariDOMBridge.listTabs()])
            case .rrwebStart:
                guard let rrwebRequest = request.rrwebRequest,
                      let tabID = rrwebRequest.tabID, tabID > 0,
                      rrwebRequest.recordingPath == nil,
                      rrwebRequest.recordingID == nil,
                      rrwebRequest.includeEvents == false,
                      rrwebRequest.eventLimit == 1_000 else {
                    throw RecordingError.usage("rrweb.start requires a positive tabID.")
                }
                guard let tab = try await safariDOMBridge.listTabs().first(where: { $0.id == tabID }) else {
                    throw RecordingError.capture(
                        "That Safari tab is not currently active and unlocked. Refresh safari.tabs and retry."
                    )
                }
                await startRRWebRecording(tab: tab)
                guard activeRRWebRecording?.manifest.tab.id == tabID else {
                    throw RecordingError.capture(errorMessage ?? "The rrweb recording did not start.")
                }
                output = try rrwebStatusOutput()
            case .rrwebPause:
                guard activeRRWebRecording?.manifest.state == .recording else {
                    throw RecordingError.capture("There is no recording rrweb session to pause.")
                }
                await pauseRRWebRecording()
                guard activeRRWebRecording?.manifest.state == .paused else {
                    throw RecordingError.capture(errorMessage ?? "The rrweb recording did not pause.")
                }
                output = try rrwebStatusOutput()
            case .rrwebResume:
                guard activeRRWebRecording?.manifest.state == .paused else {
                    throw RecordingError.capture("There is no paused rrweb session to resume.")
                }
                await resumeRRWebRecording()
                guard activeRRWebRecording?.manifest.state == .recording else {
                    throw RecordingError.capture(errorMessage ?? "The rrweb recording did not resume.")
                }
                output = try rrwebStatusOutput()
            case .rrwebStop:
                guard activeRRWebRecording != nil else {
                    throw RecordingError.capture("There is no active rrweb recording to stop.")
                }
                await stopRRWebRecording()
                output = try rrwebStatusOutput()
            case .rrwebStatus:
                await refreshActiveRRWebStatus(reportErrors: false)
                output = try rrwebStatusOutput()
            case .rrwebRecordings:
                output = try rrwebRecordingsOutput()
            case .rrwebInspect:
                guard let rrwebRequest = request.rrwebRequest else {
                    throw RecordingError.usage("rrweb.inspect did not include a request.")
                }
                output = try rrwebInspectOutput(rrwebRequest)
            case .safariDOM:
                guard let safariRequest = request.safariDOMRequest else {
                    throw RecordingError.usage("The Safari DOM command did not include a request.")
                }
                guard !safariRequest.kind.isRRWebCommand else {
                    throw RecordingError.usage("Use the rrweb.* endpoints for rrweb recording control.")
                }
                if safariRequest.kind.isMutation {
                    let action = safariAutomationAction(for: safariRequest)
                    let actionID = UUID()
                    let recordingWasPaused = status == .paused
                    try recordAutomationActionIfApplicable(
                        action,
                        actionID: actionID,
                        phase: .requested,
                        caller: caller,
                        recordingWasPaused: recordingWasPaused
                    )
                    do {
                        output = try await safariDOMBridge.perform(safariRequest)
                        try recordAutomationActionIfApplicable(
                            action,
                            actionID: actionID,
                            phase: .succeeded,
                            caller: caller,
                            recordingWasPaused: recordingWasPaused
                        )
                    } catch {
                        try? recordAutomationActionIfApplicable(
                            action,
                            actionID: actionID,
                            phase: .failed,
                            caller: caller,
                            recordingWasPaused: recordingWasPaused
                        )
                        throw error
                    }
                } else {
                    output = try await safariDOMBridge.perform(safariRequest)
                }
            }
            return PabloControlResponse(
                id: request.id,
                result: controlResult(annotation: annotation, output: output)
            )
        } catch {
            return PabloControlResponse(id: request.id, error: error.localizedDescription)
        }
    }

    private func recordAutomationActionIfApplicable(
        _ action: PabloLiveActionRequest,
        actionID: UUID,
        phase: PabloAutomationActionPhase,
        caller: ControlCaller,
        recordingWasPaused: Bool
    ) throws {
        guard let session else { return }
        let actionTargetPID = resolvedTargetPID(for: action.target)
        try session.recordAutomationAction(PabloAutomationActionTrace(
            actionID: actionID,
            phase: phase,
            request: action,
            caller: caller.automationCaller,
            transport: "http+unix",
            recordingWasPaused: recordingWasPaused
        ), actionTargetPID: actionTargetPID)
    }

    private func safariAutomationAction(for request: PabloSafariDOMRequest) -> PabloLiveActionRequest {
        PabloLiveActionRequest(
            kind: .perform,
            target: PabloLiveApplicationTarget(bundleIdentifier: "com.apple.Safari"),
            nodeID: request.nodeID ?? request.selector,
            text: request.kind == .setValue ? request.value : nil,
            accessibilityAction: "safari.dom.\(request.kind.rawValue)"
        )
    }

    private func resolvedTargetPID(for target: PabloLiveApplicationTarget) -> pid_t? {
        if let pid = target.pid { return pid }
        return NSWorkspace.shared.runningApplications.first { application in
            guard !application.isTerminated else { return false }
            if let bundleIdentifier = target.bundleIdentifier {
                return application.bundleIdentifier == bundleIdentifier
            }
            if let appName = target.appName {
                return application.localizedName?.localizedCaseInsensitiveCompare(appName) == .orderedSame
            }
            return false
        }?.processIdentifier
    }

    private func approveControlAccessIfNeeded(
        _ request: PabloControlRequest,
        caller: ControlCaller
    ) -> Bool {
        if let cacheIdentity = caller.cacheIdentity,
           dailyApprovalStore.isApprovedToday(applicationIdentity: cacheIdentity) {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow \(caller.displayName) to access Pablo today?"
        var identityDetails: [String] = []
        if let identifier = caller.applicationIdentifier {
            identityDetails.append("App identifier: \(identifier)")
        }
        if let developerName = caller.developerName {
            identityDetails.append("Developer: \(developerName)")
        }
        if let teamIdentifier = caller.developerTeamIdentifier {
            identityDetails.append("Developer team: \(teamIdentifier)")
        }
        if caller.cacheIdentity == nil {
            identityDetails.append("Developer: Unverified")
        }
        let identityDetail = identityDetails.isEmpty ? "" : "\n" + identityDetails.joined(separator: "\n")
        let persistenceDetail = caller.cacheIdentity == nil
            ? "Pablo could not verify a stable identity for this caller, so it will ask again next time."
            : "Pablo will allow this verified app to send control commands until the calendar day changes."
        alert.informativeText = "\(controlRequestDescription(request))\(identityDetail)\n\n\(persistenceDetail)"
        alert.addButton(withTitle: caller.cacheIdentity == nil ? "Allow Once" : "Allow for Today")
        alert.addButton(withTitle: "Deny")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if let cacheIdentity = caller.cacheIdentity {
            dailyApprovalStore.approveForToday(applicationIdentity: cacheIdentity)
        }
        return true
    }

    private func annotationAuthor(for caller: ControlCaller) -> RecordingAnnotationAuthor {
        RecordingAnnotationAuthor(
            type: .application,
            displayName: caller.displayName,
            applicationIdentifier: caller.applicationIdentifier,
            developerName: caller.developerName,
            developerTeamIdentifier: caller.developerTeamIdentifier
        )
    }

    private func controlCaller(for peer: PabloControlPeer) -> ControlCaller {
        guard let pid = peer.processIdentifier else {
            return ControlCaller(
                displayName: "Another local app",
                applicationIdentifier: nil,
                developerName: nil,
                developerTeamIdentifier: nil,
                cacheIdentity: nil
            )
        }
        let invokingApplication = invokingApplication(forChildProcess: pid)
        let identityPID = invokingApplication?.processIdentifier ?? pid
        let signingIdentity = codeSigningIdentity(for: identityPID)
        let executablePath = executablePath(for: identityPID)
        let displayName = invokingApplication?.localizedName
            ?? executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Process \(identityPID)"
        if let signingIdentity {
            return ControlCaller(
                displayName: displayName,
                applicationIdentifier: invokingApplication?.bundleIdentifier ?? signingIdentity.identifier,
                developerName: signingIdentity.developerName,
                developerTeamIdentifier: signingIdentity.teamIdentifier,
                cacheIdentity: "signed:\(signingIdentity.teamIdentifier):\(signingIdentity.identifier)"
            )
        }
        return ControlCaller(
            displayName: displayName,
            applicationIdentifier: invokingApplication?.bundleIdentifier ?? executablePath,
            developerName: nil,
            developerTeamIdentifier: nil,
            cacheIdentity: nil
        )
    }

    private func invokingApplication(forChildProcess childPID: pid_t) -> NSRunningApplication? {
        PabloProcessChain.nearestApplication(
            invokedBy: childPID,
            parentProcessIdentifier: PabloProcessChain.parentProcessIdentifier(of:),
            applicationIdentity: { pid in
                if let application = NSRunningApplication(processIdentifier: pid),
                   application.bundleIdentifier != nil,
                   application.activationPolicy != .prohibited {
                    return application
                }
                return owningApplication(forHelperProcess: pid)
            }
        )
    }

    private func owningApplication(forHelperProcess pid: pid_t) -> NSRunningApplication? {
        guard let executablePath = executablePath(for: pid),
              let bundleURL = PabloProcessChain.owningApplicationBundleURL(
                  forExecutablePath: executablePath
              ),
              let bundleIdentifier = Bundle(url: bundleURL)?.bundleIdentifier,
              let helperIdentity = codeSigningIdentity(for: pid) else { return nil }

        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { application in
                guard !application.isTerminated,
                      application.activationPolicy != .prohibited,
                      let ownerIdentity = codeSigningIdentity(for: application.processIdentifier) else {
                    return false
                }
                return ownerIdentity.teamIdentifier == helperIdentity.teamIdentifier
            }
    }

    private func codeSigningIdentity(for pid: pid_t) -> CodeSigningIdentity? {
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
                == errSecSuccess,
              let dictionary = information as? [String: Any],
              let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String else {
            return nil
        }
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let developerName = certificates?.first.flatMap {
            SecCertificateCopySubjectSummary($0) as String?
        }
        return CodeSigningIdentity(
            teamIdentifier: teamIdentifier,
            identifier: identifier,
            developerName: developerName
        )
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func controlRequestDescription(_ request: PabloControlRequest) -> String {
        if request.method == .addAnnotation,
           let annotationRequest = request.annotationRequest,
           let draft = annotationRequest.draft {
            return "This app wants to add \(draft.kind.rawValue) markup to " +
                "\(URL(fileURLWithPath: annotationRequest.recordingPath).lastPathComponent)."
        }
        if request.method == .resolveAnnotation,
           let annotationRequest = request.annotationRequest {
            return "This app wants to resolve \(annotationRequest.reference ?? "an annotation") in " +
                "\(URL(fileURLWithPath: annotationRequest.recordingPath).lastPathComponent)."
        }
        if request.method == .inspectLive,
           let inspection = request.liveInspectionRequest {
            let target = inspection.target.appName
                ?? inspection.target.bundleIdentifier
                ?? inspection.target.pid.map { "PID \($0)" }
                ?? "a live application"
            if inspection.kind == .events {
                return "This app wants to inspect input directed to \(target). " +
                    "Typed text will be retained in memory while Pablo remains open."
            }
            return "This app wants to inspect the current accessibility state of \(target). " +
                "Live inspection data remains in memory and is not saved as a recording."
        }
        if request.method == .actLive,
           let action = request.liveActionRequest {
            let target = action.target.appName
                ?? action.target.bundleIdentifier
                ?? action.target.pid.map { "PID \($0)" }
                ?? "a live application"
            let detail: String
            switch action.kind {
            case .click: detail = "click in"
            case .drag: detail = "drag in"
            case .scroll: detail = "scroll"
            case .typeText: detail = "type text into"
            case .key: detail = "send a key to"
            case .perform: detail = "perform an accessibility action in"
            }
            let foregroundDetail = action.unlockForegroundActions
                ? " This request unlocks foreground actions, so Pablo may switch focus to that application. " +
                    "Unlocking foreground actions is NOT RECOMMENDED."
                : " Pablo will keep that application in the background or reject the action."
            return "This app wants to \(detail) \(target). " +
                "The action will control that application through Pablo." + foregroundDetail
        }
        if request.method == .safariDOM,
           let safariRequest = request.safariDOMRequest {
            switch safariRequest.kind {
            case .listTabs:
                return "This app wants to list active Safari tabs you explicitly unlocked."
            case .startRRWebRecording, .pauseRRWebRecording, .resumeRRWebRecording,
                 .stopRRWebRecording, .rrwebRecordingStatus:
                return "This app wants to control an rrweb recording in an unlocked Safari tab."
            case .dumpDOM:
                return "This app wants to dump the DOM of the Safari tab you explicitly unlocked. " +
                    "Safari will remain in the background."
            case .dumpAccessibilityTree:
                return "This app wants to inspect a DOM-derived accessibility tree for the Safari tab " +
                    "you explicitly unlocked. Safari will remain in the background."
            case .click, .focus, .setValue, .scrollIntoView:
                return "This app wants to perform a \(safariRequest.kind.rawValue) DOM action in the Safari tab " +
                    "you explicitly unlocked. Safari will remain in the background."
            }
        }
        switch request.method {
        case .safariTabs:
            return "This app wants to list active Safari tabs you explicitly unlocked."
        case .rrwebStart:
            return "This app wants to start an rrweb recording of an unlocked Safari tab. " +
                "Input values will be masked and Safari will remain in the background."
        case .rrwebPause, .rrwebResume, .rrwebStop:
            return "This app wants to \(request.method.approvalDescription)."
        case .rrwebStatus, .rrwebRecordings, .rrwebInspect:
            return "This app wants to \(request.method.approvalDescription)."
        default:
            break
        }
        guard request.method == .startRecording, let options = request.recordOptions else {
            return "This app wants to \(request.method.approvalDescription)."
        }
        let target = options.scope == .display
            ? options.displayID.map { "display \($0) and interactions across its applications" }
                ?? "the entire main display and interactions across its applications"
            : options.appName
                ?? options.bundleIdentifier
                ?? options.pid.map { "PID \($0)" }
                ?? "an application"
        let textNotice = options.captureText ? " Typed text will be captured." : " Typed text will not be captured."
        return "This app wants to start a recording of \(target).\(textNotice)"
    }

    private func controlResult(
        annotation: RecordingAnnotation? = nil,
        output: PabloControlOutput? = nil
    ) -> PabloControlResult {
        let state: String
        switch status {
        case .idle:
            if activeRRWebRecording?.manifest.state == .recording {
                state = "rrweb-recording"
            } else if activeRRWebRecording?.manifest.state == .paused {
                state = "rrweb-paused"
            } else {
                state = "idle"
            }
        case .starting: state = "starting"
        case .recording: state = "recording"
        case .paused: state = "paused"
        case .stopping: state = "stopping"
        }
        return PabloControlResult(
            state: state,
            scopeName: session?.scopeName,
            applicationIDs: session?.applicationIDs ?? [],
            recordingPath: session?.packageURL.path ?? lastRecordingURL?.path,
            elapsedNanoseconds: session?.durationNs ?? elapsedNanoseconds,
            annotation: annotation,
            output: output
        )
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
        let directory = Self.recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(directory) else {
                throw RecordingError.capture("Finder could not open the recordings directory.")
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not show recordings: \(error.localizedDescription)"
        }
    }

    func openPrivacySettings(_ pane: PrivacyPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private static var recordingsDirectory: URL {
        PabloRecordingStorage.localRecordingsDirectory
    }
}

private struct RRWebAPIRecording: Encodable {
    let path: String
    let manifest: PabloRRWebRecordingManifest

    init(recording: PabloRRWebRecording) {
        path = recording.packageURL.path
        manifest = recording.manifest
    }
}

private struct RRWebAPIStatus: Encodable {
    let active: RRWebAPIRecording?
    let eventCount: Int
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

struct RecorderWindowView: View {
    @ObservedObject var model: RecorderModel
    let showReview: @MainActor (URL?) -> Void
    let openRecordings: @MainActor () -> Void
    @State private var copiedAgentInstructions = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: model.menuBarSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Pablo Recorder").font(.title2.weight(.semibold))
                    Text(model.statusTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let scopeName = model.activeScopeName {
                    Label(scopeName, systemImage: "record.circle")
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if model.isActive || model.status == .stopping {
                    Text(formattedDuration)
                        .font(.system(.title2, design: .monospaced, weight: .medium))
                        .contentTransition(.numericText())
                }
            }

            Divider()

            controlRow

            rrwebSection

            if let error = model.errorMessage {
                errorCard(error)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Working with an agent?")
                        .font(.subheadline.weight(.medium))
                    Text("Copy the local API, safety rules, and discovery command.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyAgentInstructions()
                } label: {
                    Label(
                        copiedAgentInstructions ? "Copied" : "Copy Agent Instructions",
                        systemImage: copiedAgentInstructions ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .help("Copy instructions for controlling Pablo with an agent")
            }

            Spacer(minLength: 0)

            Divider()

            HStack(spacing: 12) {
                Button("Open Review") { showReview(model.lastRecordingURL) }
                Button("Open Recordings…", action: openRecordings)
                Button("Show Recordings") { model.revealRecordings() }
                Spacer()
                Button("Quit Pablo") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 500, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshApplications()
            Task { await model.refreshSafariTabs() }
        }
        .onReceive(timer) { _ in
            model.updateElapsedTime()
            model.refreshRRWebStatusIfNeeded()
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
        }
    }

    private var rrwebSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let recording = model.activeRRWebRecording {
                    HStack(spacing: 10) {
                        Image(systemName: "safari")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.manifest.tab.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text("\(recording.manifest.state.rawValue.capitalized) · \(model.rrwebEventCount) rrweb events · inputs masked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                if recording.manifest.state == .paused {
                                    await model.resumeRRWebRecording()
                                } else {
                                    await model.pauseRRWebRecording()
                                }
                            }
                        } label: {
                            Label(
                                recording.manifest.state == .paused ? "Resume" : "Pause",
                                systemImage: recording.manifest.state == .paused ? "play.fill" : "pause.fill"
                            )
                        }
                        Button(role: .destructive) {
                            Task { await model.stopRRWebRecording() }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                } else if model.safariTabs.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No unlocked active Safari tabs")
                                .font(.subheadline.weight(.medium))
                            Text("Enable Pablo Safari, then click its toolbar button in each tab you want listed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.refreshingSafariTabs { ProgressView().controlSize(.small) }
                        Button("Refresh") { Task { await model.refreshSafariTabs() } }
                    }
                } else {
                    ForEach(model.safariTabs) { tab in
                        HStack(spacing: 10) {
                            Image(systemName: "safari")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Record") { Task { await model.startRRWebRecording(tab: tab) } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    HStack {
                        Text("Only active tabs explicitly unlocked from Safari are shown. Input values are masked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { Task { await model.refreshSafariTabs() } }
                    }
                }
                if !model.rrwebRecordings.isEmpty {
                    Divider()
                    HStack {
                        Text("\(model.rrwebRecordings.count) saved Safari web recording\(model.rrwebRecordings.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu("Review Saved Recording") {
                            ForEach(model.rrwebRecordings.prefix(20), id: \.manifest.recordingID) { recording in
                                Button(recording.manifest.tab.title) {
                                    showReview(recording.packageURL)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Safari rrweb", systemImage: "globe")
                .font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder
    private var controlRow: some View {
        if model.status == .starting {
            HStack(spacing: 12) {
                ProgressView()
                Text("Starting recording…")
                    .font(.subheadline.weight(.medium))
            }
        } else if model.isActive || model.status == .stopping {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.status == .paused ? "Capture is paused" : "Video, input, and accessibility are recording")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        model.togglePause()
                    } label: {
                        Label(
                            model.status == .paused ? "Resume Recording" : "Pause Recording",
                            systemImage: model.status == .paused ? "play.fill" : "pause.fill"
                        )
                        .frame(minWidth: 145)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.status == .stopping)

                    Button {
                        Task { await model.stopRecording() }
                    } label: {
                        Label("Stop Recording", systemImage: "stop.fill")
                            .frame(minWidth: 145)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .disabled(model.status == .stopping)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button {
                        Task { await model.startScreenRecording() }
                    } label: {
                        Label("Record Entire Screen", systemImage: "display")
                            .frame(minWidth: 175)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canStartScreen)

                    Menu {
                        if model.applications.isEmpty {
                            Text("No recordable applications")
                        } else {
                            ForEach(model.applications) { application in
                                Button(application.name) {
                                    model.selectedPID = application.pid
                                    Task { await model.startApplicationRecording(pid: application.pid) }
                                }
                            }
                        }
                        Divider()
                        Button("Refresh Applications") { model.refreshApplications() }
                    } label: {
                        Label("Record an Application", systemImage: "macwindow")
                            .frame(minWidth: 175)
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.large)
                    .disabled(model.status != .idle)
                }

                Toggle("Capture typed text", isOn: $model.captureText)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)

                Text("Recording and markup requests from other apps still require approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Label("Pablo needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Menu("Open Privacy Settings") {
                ForEach(PrivacyPane.allCases) { pane in
                    Button(pane.rawValue) { model.openPrivacySettings(pane) }
                }
            }
            .font(.caption)
        }
        .padding(9)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var statusColor: Color {
        if model.status == .idle, let state = model.activeRRWebRecording?.manifest.state {
            if state == .recording { return .red }
            if state == .paused { return .orange }
        }
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

    private func copyAgentInstructions() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(agentInstructions, forType: .string) else { return }

        copiedAgentInstructions = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedAgentInstructions = false
        }
    }

    private var agentInstructions: String {
        let escapedSocketPath = PabloControlSocket.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        Use Pablo to record, inspect, and control Mac apps on this computer.

        Pablo is running. Set its Unix-domain socket once in your shell:
        export PABLO_SOCKET="\(escapedSocketPath)"

        Start by fetching the self-describing OpenAPI contract:
        curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/openapi.json

        Put the method in the URL and pass only its JSON payload:
        curl -fsS --unix-socket "$PABLO_SOCKET" -d '{"kind":"frames","target":{"appName":"Notes"}}' http://localhost/inspect.live

        Bodyless calls need only the method URL, for example:
        curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/record.status

        Safari web recording starts with explicit tab discovery:
        curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/safari.tabs
        curl -fsS --unix-socket "$PABLO_SOCKET" -d '{"tabID":42}' http://localhost/rrweb.start

        Rules:
        - Only start a recording when I explicitly ask.
        - Never approve Pablo's consent dialog; leave approval to me.
        - Inspect a fresh accessibility frame before taking live actions.
        - Safari DOM access requires enabling Pablo Safari and clicking its toolbar button on the active tab. Use `/safari.dom`; the grant ends when that tab navigates.
        - Safari DOM commands run through the extension without bringing Safari to the foreground. Dump a fresh DOM-derived accessibility tree before using its `nodeID` as an action target.
        - Use `/safari.tabs` and `/rrweb.start`, `/rrweb.pause`, `/rrweb.resume`, `/rrweb.stop`, `/rrweb.status`, `/rrweb.recordings`, or `/rrweb.inspect` for masked Safari web recordings. The server generates recording IDs.
        - rrweb masks input values, but page text, titles, URLs, and other rendered content remain sensitive.
        - Foreground actions are locked by default. Prefer `perform` or a single left click on a node that exposes `AXPress`; these do not activate the target app.
        - `unlockForegroundActions: true` (CLI: `--unlock-foreground-actions`) allows focus-changing pointer, scroll, drag, typing, and key actions. This is NOT RECOMMENDED. Never use it unless I explicitly accept the focus change.
        - Honor action-time confirmation requirements for consequential operations.
        - Treat recordings as sensitive because they can contain visible and typed text.
        - Do not add protocol-version, request-ID, or method fields to request bodies.
        - Live inspection output is always pretty-printed structured JSON.
        - Any HTTP verb works; curl's `-d` uses POST automatically.
        """
    }
}

private struct StatusPanel: View {
    @ObservedObject var model: RecorderModel
    let showReview: @MainActor (URL?) -> Void
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380)
        .onReceive(timer) { _ in
            model.updateElapsedTime()
            model.refreshRRWebStatusIfNeeded()
        }
        .onAppear {
            model.refreshApplications()
            Task { await model.refreshSafariTabs() }
        }
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
            if model.status == .starting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Starting recording…")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.isActive || model.status == .stopping {
                activeControls
            } else {
                idleControls
            }

            Divider()
            rrwebMenuControls

            if let error = model.errorMessage {
                errorCard(error)
            }
        }
        .padding(14)
    }

    private var rrwebMenuControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Safari rrweb", systemImage: "safari")
                .font(.caption.weight(.semibold))
            if let recording = model.activeRRWebRecording {
                Text(recording.manifest.tab.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(recording.manifest.state.rawValue.capitalized) · \(model.rrwebEventCount) events · inputs masked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        Task {
                            if recording.manifest.state == .paused {
                                await model.resumeRRWebRecording()
                            } else {
                                await model.pauseRRWebRecording()
                            }
                        }
                    } label: {
                        Label(
                            recording.manifest.state == .paused ? "Resume" : "Pause",
                            systemImage: recording.manifest.state == .paused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        Task { await model.stopRRWebRecording() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } else {
                Menu {
                    if model.safariTabs.isEmpty {
                        Text("No unlocked active tabs")
                    } else {
                        ForEach(model.safariTabs) { tab in
                            Button(tab.title) { Task { await model.startRRWebRecording(tab: tab) } }
                        }
                    }
                    Divider()
                    Button("Refresh Tabs") { Task { await model.refreshSafariTabs() } }
                } label: {
                    Label("Record an Unlocked Safari Tab", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)
                Text("Click Pablo Safari in a tab first. rrweb masks input values and stops at navigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.rrwebRecordings.isEmpty {
                Menu("Review Saved Recording") {
                    ForEach(model.rrwebRecordings.prefix(20), id: \.manifest.recordingID) { recording in
                        Button(recording.manifest.tab.title) {
                            showReview(recording.packageURL)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.startScreenRecording() }
            } label: {
                Label("Record Entire Screen", systemImage: "display")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canStartScreen)

            Menu {
                if model.applications.isEmpty {
                    Text("No recordable applications")
                } else {
                    ForEach(model.applications) { application in
                        Button(application.name) {
                            model.selectedPID = application.pid
                            Task { await model.startApplicationRecording(pid: application.pid) }
                        }
                    }
                }
                Divider()
                Button("Refresh Applications") { model.refreshApplications() }
            } label: {
                Label("Record an Application", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.large)
            .disabled(model.status != .idle)

            Toggle("Capture typed text", isOn: $model.captureText)
                .font(.caption)

            Text("Recording and markup requests from agents still appear here for approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activeControls: some View {
        VStack(spacing: 12) {
            if let scopeName = model.activeScopeName {
                HStack {
                    Image(systemName: "macwindow")
                        .foregroundStyle(.secondary)
                    Text(scopeName)
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
            Label("Pablo needs attention", systemImage: "exclamationmark.triangle.fill")
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
            Button("Open Review") {
                showReview(model.lastRecordingURL)
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 12)
            Button("Show Recordings") { model.revealRecordings() }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        if model.status == .idle, let state = model.activeRRWebRecording?.manifest.state {
            if state == .recording { return .red }
            if state == .paused { return .orange }
        }
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
