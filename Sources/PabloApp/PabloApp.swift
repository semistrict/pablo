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
        showRecorderWindow()
        let recordingURLs = pendingRecordingURLs
        pendingRecordingURLs.removeAll()
        for recordingURL in recordingURLs {
            showReviewWindow(preferredURL: recordingURL)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let recordingURLs = urls
            .filter { $0.pathExtension.caseInsensitiveCompare("pablo") == .orderedSame }
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
        window.minSize = NSSize(width: 580, height: 350)
        window.setContentSize(NSSize(width: 680, height: 340))
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
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for recordingURL in panel.urls where
                recordingURL.pathExtension.caseInsensitiveCompare("pablo") == .orderedSame {
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

    private var session: RecordingSession?
    private var automaticStopTask: Task<Void, Never>?
    private let dailyApprovalStore = PabloDailyApprovalStore()
    private let liveInspectionManager = PabloLiveInspectionManager()
    private lazy var liveActionController = PabloLiveActionController(
        inspectionManager: liveInspectionManager
    )
    private lazy var controlServer = PabloControlServer { [weak self] request, peer in
        guard let self else {
            return PabloControlResponse(id: request.id, error: "Pablo is shutting down.")
        }
        return await self.handleControlRequest(request, from: peer)
    }

    init() {
        Task { @MainActor [weak self] in self?.startControlServer() }
    }

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

    var canStartApplication: Bool { status == .idle && selectedPID != nil }
    var canStartScreen: Bool { status == .idle }
    var isActive: Bool { status == .recording || status == .paused }
    var activeScopeName: String? { session?.scopeName }

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

    func startApplicationRecording(pid: pid_t? = nil) async {
        let pid = pid ?? selectedPID
        guard status == .idle, let pid else { return }
        errorMessage = nil
        status = .starting
        do {
            var options = RecordOptions()
            options.scope = .application
            options.pid = pid
            options.outputURL = try nextRecordingURL()
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
            options.outputURL = try nextRecordingURL()
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
        guard isActive else { return }
        automaticStopTask?.cancel()
        automaticStopTask = nil
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
            var output: String?
            switch request.method {
            case .startRecording:
                guard status == .idle else {
                    throw RecordingError.capture("Pablo is already recording or changing state.")
                }
                guard let remoteOptions = request.recordOptions else {
                    throw RecordingError.usage("The start command did not include recording options.")
                }
                var options = remoteOptions.recordOptions()
                if options.outputURL == nil { options.outputURL = try nextRecordingURL() }
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
                output = try liveInspectionManager.perform(inspection)
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
                    output = try await liveActionController.perform(action)
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
            transport: "pabloCLI",
            recordingWasPaused: recordingWasPaused
        ), actionTargetPID: actionTargetPID)
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
            parentProcessIdentifier: parentProcessIdentifier(of:),
            applicationIdentity: { pid in
                guard let application = NSRunningApplication(processIdentifier: pid),
                      application.bundleIdentifier != nil,
                      application.activationPolicy != .prohibited else { return nil }
                return application
            }
        )
    }

    private func parentProcessIdentifier(of pid: pid_t) -> pid_t? {
        var information = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, expectedSize)
        guard actualSize == expectedSize, information.pbi_ppid > 0 else { return nil }
        return pid_t(information.pbi_ppid)
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
            return "This app wants to \(detail) \(target). " +
                "The action will control that application through Pablo."
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
        output: String? = nil
    ) -> PabloControlResult {
        let state: String
        switch status {
        case .idle: state = "idle"
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

struct RecorderWindowView: View {
    @ObservedObject var model: RecorderModel
    let showReview: @MainActor (URL?) -> Void
    let openRecordings: @MainActor () -> Void
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

            if let error = model.errorMessage {
                errorCard(error)
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
        .frame(minWidth: 520, minHeight: 270, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refreshApplications() }
        .onReceive(timer) { _ in model.updateElapsedTime() }
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
        .frame(width: 340)
        .onReceive(timer) { _ in model.updateElapsedTime() }
        .onAppear { model.refreshApplications() }
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

            if let error = model.errorMessage {
                errorCard(error)
            }
        }
        .padding(14)
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
