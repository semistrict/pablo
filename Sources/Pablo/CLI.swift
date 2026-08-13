import ApplicationServices
import Foundation

public struct RecordOptions {
    public var scope: RecordingScopeKind = .application
    public var pid: pid_t?
    public var bundleIdentifier: String?
    public var appName: String?
    public var displayID: UInt32?
    public var outputURL: URL?
    public var duration: TimeInterval?
    public var snapshotInterval: TimeInterval = 1
    public var captureText = true
    public var framesPerSecond = 30

    public init() {}
}

public struct AnnotationOptions {
    public var recordingURL: URL?
    public var kind: RecordingAnnotationKind = .observation
    public var text: String?
    public var at: TimeInterval?
    public var from: TimeInterval?
    public var to: TimeInterval?
    public var accessibilityReferences: [String] = []
    public var applicationIDs: [String] = []
    public var accessibilityNodeIDs: [String] = []
    public var point: AnnotationPoint?
    public var tracePoints: [AnnotationTracePoint] = []
    public var lineWidth: Double = 0.008

    public init() {}
}

public struct AnnotationPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct AnnotationTracePoint: Equatable, Sendable {
    public let videoTime: TimeInterval
    public let x: Double
    public let y: Double

    public init(videoTime: TimeInterval, x: Double, y: Double) {
        self.videoTime = videoTime
        self.x = x
        self.y = y
    }
}

public enum InspectionSource: Equatable, Sendable {
    case recording(URL?)
    case live(PabloLiveApplicationTarget)
}

public enum Command {
    case record(RecordOptions)
    case status
    case pause
    case resume
    case stop
    case inspect(InspectionSource)
    case latest
    case recordings(json: Bool)
    case frames(InspectionSource, json: Bool)
    case frame(reference: String, source: InspectionSource, changedOnly: Bool, json: Bool)
    case events(InspectionSource, limit: Int, json: Bool)
    case workspace(recording: URL?, json: Bool)
    case annotations(InspectionSource, json: Bool)
    case liveAction(PabloLiveActionRequest)
    case annotate(AnnotationOptions)
    case resolveAnnotation(reference: String, recording: URL?)
    case help
}

public enum CLI {
    public static func parse(_ arguments: [String]) throws -> Command {
        guard let command = arguments.first else { return .help }
        switch command {
        case "record":
            var options = RecordOptions()
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--screen":
                    options.scope = .display
                case "--display-id":
                    let value = try next(arguments, &index, option: argument)
                    guard let parsed = UInt32(value) else {
                        throw RecordingError.usage("--display-id must be an unsigned display ID.")
                    }
                    options.scope = .display
                    options.displayID = parsed
                case "--pid":
                    let value = try next(arguments, &index, option: argument)
                    guard let parsed = pid_t(value), parsed > 0 else {
                        throw RecordingError.usage("--pid must be a positive process ID.")
                    }
                    options.pid = parsed
                case "--bundle-id":
                    options.bundleIdentifier = try next(arguments, &index, option: argument)
                case "--app":
                    options.appName = try next(arguments, &index, option: argument)
                case "--output", "-o":
                    options.outputURL = URL(fileURLWithPath: try next(arguments, &index, option: argument))
                case "--duration":
                    let value = try next(arguments, &index, option: argument)
                    guard let parsed = TimeInterval(value), parsed > 0 else {
                        throw RecordingError.usage("--duration must be greater than zero.")
                    }
                    options.duration = parsed
                case "--snapshot-interval":
                    let value = try next(arguments, &index, option: argument)
                    guard let parsed = TimeInterval(value), parsed >= 0 else {
                        throw RecordingError.usage("--snapshot-interval must be zero or greater.")
                    }
                    options.snapshotInterval = parsed
                case "--fps":
                    let value = try next(arguments, &index, option: argument)
                    guard let parsed = Int(value), (1...60).contains(parsed) else {
                        throw RecordingError.usage("--fps must be between 1 and 60.")
                    }
                    options.framesPerSecond = parsed
                case "--no-text":
                    options.captureText = false
                case "--help", "-h":
                    return .help
                default:
                    throw RecordingError.usage("Unknown option: \(argument)")
                }
                index += 1
            }
            let selectors = [options.pid != nil, options.bundleIdentifier != nil, options.appName != nil].filter { $0 }.count
            if options.scope == .display {
                guard selectors == 0 else {
                    throw RecordingError.usage("--screen cannot be combined with an application selector.")
                }
            } else if selectors != 1 {
                throw RecordingError.usage("Choose --screen or exactly one application with --app, --bundle-id, or --pid.")
            }
            return .record(options)
        case "status":
            try requireNoArguments(arguments, usage: "pablo status")
            return .status
        case "pause":
            try requireNoArguments(arguments, usage: "pablo pause")
            return .pause
        case "resume":
            try requireNoArguments(arguments, usage: "pablo resume")
            return .resume
        case "stop":
            try requireNoArguments(arguments, usage: "pablo stop")
            return .stop
        case "inspect":
            let parsed = try parseInspectionArguments(Array(arguments.dropFirst()))
            return .inspect(parsed.source)
        case "latest":
            guard arguments.count == 1 else {
                throw RecordingError.usage("Usage: pablo latest")
            }
            return .latest
        case "recordings", "list":
            let parsed = try parseRecordingArguments(Array(arguments.dropFirst()), allowsURL: false)
            return .recordings(json: parsed.json)
        case "frames":
            let parsed = try parseInspectionArguments(Array(arguments.dropFirst()))
            return .frames(parsed.source, json: parsed.json)
        case "frame":
            guard arguments.count >= 2 else {
                throw RecordingError.usage("Usage: pablo frame <A11Y-###> [recording.pablo] [--changed] [--json]")
            }
            let reference = arguments[1]
            let parsed = try parseInspectionArguments(
                Array(arguments.dropFirst(2)),
                allowsChanged: true
            )
            return .frame(
                reference: reference,
                source: parsed.source,
                changedOnly: parsed.changed,
                json: parsed.json
            )
        case "events":
            let parsed = try parseInspectionArguments(Array(arguments.dropFirst()), allowsLimit: true)
            return .events(parsed.source, limit: parsed.limit ?? 100, json: parsed.json)
        case "workspace":
            let parsed = try parseRecordingArguments(Array(arguments.dropFirst()))
            return .workspace(recording: parsed.url, json: parsed.json)
        case "annotations", "notes":
            let parsed = try parseInspectionArguments(Array(arguments.dropFirst()))
            return .annotations(parsed.source, json: parsed.json)
        case "click":
            return .liveAction(try parseLiveAction(.click, arguments: Array(arguments.dropFirst())))
        case "drag":
            return .liveAction(try parseLiveAction(.drag, arguments: Array(arguments.dropFirst())))
        case "scroll":
            return .liveAction(try parseLiveAction(.scroll, arguments: Array(arguments.dropFirst())))
        case "type":
            return .liveAction(try parseLiveAction(.typeText, arguments: Array(arguments.dropFirst())))
        case "key":
            return .liveAction(try parseLiveAction(.key, arguments: Array(arguments.dropFirst())))
        case "perform":
            return .liveAction(try parseLiveAction(.perform, arguments: Array(arguments.dropFirst())))
        case "annotate":
            return .annotate(try parseAnnotationOptions(Array(arguments.dropFirst())))
        case "resolve":
            guard arguments.count >= 2 else {
                throw RecordingError.usage("Usage: pablo resolve <NOTE-###> [recording.pablo]")
            }
            let parsed = try parseRecordingArguments(Array(arguments.dropFirst(2)))
            return .resolveAnnotation(reference: arguments[1], recording: parsed.url)
        case "help", "--help", "-h":
            return .help
        default:
            throw RecordingError.usage("Unknown command: \(command)")
        }
    }

    public static let help = """
    Usage:
      pablo record (--screen [--display-id ID] | --app NAME | --bundle-id ID | --pid PID) [options]
      pablo status
      pablo pause
      pablo resume
      pablo stop
      pablo recordings [--json]
      pablo latest
      pablo inspect [recording.pablo | live target]
      pablo frames [recording.pablo | live target] [--json]
      pablo frame <A11Y-###> [recording.pablo | live target] [--changed] [--json]
      pablo events [recording.pablo | live target] [--limit N] [--json]
      pablo workspace [recording.pablo] [--json]
      pablo annotations [recording.pablo | live target] [--json]
      pablo click live-target (--node ID | --point X,Y) [--button BUTTON] [--count N]
      pablo drag live-target (--from X,Y | --from-node ID) (--to X,Y | --to-node ID)
      pablo scroll live-target --direction DIRECTION [--amount N] [--node ID | --point X,Y]
      pablo type live-target --text TEXT [--node ID]
      pablo key live-target --key KEY [--modifiers LIST]
      pablo perform live-target --node ID --action ACTION
      pablo annotate [recording.pablo] --text TEXT [markup options]
      pablo resolve <NOTE-###> [recording.pablo]

    Record options:
      --screen                  Record the entire main display and every interacting app
      --display-id ID           Record a specific display instead of the main display
      -o, --output PATH          Output package (default: ~/Movies/Pablo Recordings)
      --duration SECONDS        Stop automatically; otherwise use pablo stop
      --snapshot-interval SEC   Periodic accessibility snapshot interval (default: 1)
      --fps FPS                 Video frame rate from 1 to 60 (default: 30)
      --no-text                 Keep key codes but omit typed Unicode text

    Live target:
      --app NAME               Inspect a running application by name
      --bundle-id ID           Inspect a running application by bundle identifier
      --pid PID                Inspect a running application by process ID

    Live action options:
      --node ID                Target an accessibility node from a live frame
      --point X,Y              Target normalized coordinates in the largest window
      --button BUTTON          left, right, or middle (default: left)
      --count N                Click count from 1 to 3 (default: 1)
      --from X,Y / --to X,Y    Normalized drag endpoints
      --from-node / --to-node  Accessibility-node drag endpoints
      --duration SECONDS       Drag duration from 0.05 to 10 (default: 0.5)
      --direction DIRECTION    up, down, left, or right
      --amount N               Scroll lines from 1 to 100 (default: 3)
      --text TEXT              Text to type into the focused or selected control
      --key KEY                A letter, digit, or named key such as return or escape
      --modifiers LIST         Comma-separated command, option, control, shift, function
      --action ACTION          An accessibility action such as press, show-menu, or increment

    Markup options:
      --kind KIND              issue, observation, question, or highlight
      --at SECONDS             Pin to a video time
      --from SEC --to SEC      Mark a video time range
      --frame A11Y-###         Attach an accessibility frame; repeatable
      --application APP-###    Attach an application identity; repeatable
      --node ID                Attach an accessibility node; repeatable
      --point X,Y              Pin one normalized video point to --at or --from/--to
      --trace SEC,X,Y          Add a timed freehand sample; repeat in drawing order
      --line-width FRACTION    Trace width relative to the video (default: 0.008)

    Example:
      pablo record --screen --duration 30 -o desktop-session.pablo
      pablo record --app Notes --duration 20 -o notes-session.pablo

    Recording controls are sent to the Pablo app and require daily approval per calling application.
    Inspection commands default to the latest recording in ~/Movies/Pablo Recordings.
    Live inspection is memory-only and goes through the running Pablo app for approval.
    The first live events request begins observing input directed to the target app.
    Use the stable A11Y-### references in the app or CLI to discuss a specific frame.
    """

    public static func sendControl(
        method: PabloControlMethod,
        options: RecordOptions? = nil
    ) throws -> PabloControlResult {
        let request = PabloControlRequest(
            method: method,
            recordOptions: options.map(PabloControlRecordOptions.init)
        )
        return try send(request)
    }

    public static func addAnnotation(_ options: AnnotationOptions) throws -> PabloControlResult {
        guard let text = options.text else {
            throw RecordingError.usage("Annotation text cannot be empty.")
        }
        let packageURL = try resolveRecording(options.recordingURL)
        let recording = try ReplayRecording.load(from: packageURL)
        var startVideoTime = options.at ?? options.from
        var endVideoTime = options.at ?? options.to
        let trace: RecordingAnnotationTrace?
        if !options.tracePoints.isEmpty {
            let samples = options.tracePoints.map {
                RecordingAnnotationTraceSample(
                    timestampNs: recording.sessionTimestampNs(forVideoTime: $0.videoTime),
                    x: $0.x,
                    y: $0.y
                )
            }
            trace = RecordingAnnotationTrace(samples: samples, lineWidth: options.lineWidth)
            startVideoTime = options.tracePoints.first?.videoTime
            endVideoTime = options.tracePoints.last?.videoTime
        } else if let point = options.point,
                  let start = startVideoTime,
                  let end = endVideoTime {
            var samples = [RecordingAnnotationTraceSample(
                timestampNs: recording.sessionTimestampNs(forVideoTime: start),
                x: point.x,
                y: point.y
            )]
            if end > start {
                samples.append(RecordingAnnotationTraceSample(
                    timestampNs: recording.sessionTimestampNs(forVideoTime: end),
                    x: point.x,
                    y: point.y
                ))
            }
            trace = RecordingAnnotationTrace(samples: samples, lineWidth: options.lineWidth)
        } else {
            trace = nil
        }
        var startTimestampNs = startVideoTime.map(recording.sessionTimestampNs(forVideoTime:))
        var endTimestampNs = endVideoTime.map(recording.sessionTimestampNs(forVideoTime:))
        if startTimestampNs == nil,
           let reference = options.accessibilityReferences.first,
           let step = try? accessibilityStep(reference, in: recording) {
            startTimestampNs = step.timestampNs
            endTimestampNs = step.timestampNs
        }
        var applicationIDs = Set(options.applicationIDs)
        for reference in options.accessibilityReferences {
            if let step = try? accessibilityStep(reference, in: recording) {
                applicationIDs.insert(step.applicationID)
            }
        }
        for sample in trace?.samples ?? [] {
            if let applicationID = recording.applicationID(
                atNormalizedX: sample.x,
                y: sample.y,
                timestampNs: sample.timestampNs
            ) {
                applicationIDs.insert(applicationID)
            }
        }
        let draft = RecordingAnnotationDraft(
            kind: options.kind,
            text: text,
            startTimestampNs: startTimestampNs,
            endTimestampNs: endTimestampNs,
            applicationIDs: Array(applicationIDs).sorted(),
            accessibilityReferences: options.accessibilityReferences,
            accessibilityNodeIDs: options.accessibilityNodeIDs,
            trace: trace
        )
        return try send(PabloControlRequest(
            method: .addAnnotation,
            annotationRequest: PabloControlAnnotationRequest(
                recordingPath: packageURL.path,
                draft: draft
            )
        ))
    }

    public static func resolveAnnotation(
        reference: String,
        requestedURL: URL?
    ) throws -> PabloControlResult {
        let packageURL = try resolveRecording(requestedURL)
        return try send(PabloControlRequest(
            method: .resolveAnnotation,
            annotationRequest: PabloControlAnnotationRequest(
                recordingPath: packageURL.path,
                reference: reference
            )
        ))
    }

    private static func send(_ request: PabloControlRequest) throws -> PabloControlResult {
        let response: PabloControlResponse
        do {
            response = try PabloControlClient.send(request)
        } catch {
            try launchApp()
            response = try waitForAppAndSend(request)
        }
        if let error = response.error {
            throw RecordingError.capture(error)
        }
        guard let result = response.result else {
            throw RecordingError.capture("The Pablo app returned an empty control response.")
        }
        return result
    }

    public static func formatControlResult(_ result: PabloControlResult) -> String {
        if let output = result.output { return output }
        if let annotation = result.annotation {
            return "\(annotation.reference)  \(annotation.status.rawValue)  \(annotation.kind.rawValue)  " +
                annotation.text
        }
        var parts = [result.state]
        if let scopeName = result.scopeName { parts.append(scopeName) }
        if !result.applicationIDs.isEmpty { parts.append(result.applicationIDs.joined(separator: ",")) }
        parts.append(formatTimeNs(result.elapsedNanoseconds))
        if let recordingPath = result.recordingPath { parts.append(recordingPath) }
        return parts.joined(separator: "  ")
    }

    public static func inspect(_ source: InspectionSource) throws -> String {
        switch source {
        case .recording(let url):
            return try inspect(url)
        case .live(let target):
            return try inspectLive(.init(kind: .inspect, target: target))
        }
    }

    public static func frames(_ source: InspectionSource, json: Bool) throws -> String {
        switch source {
        case .recording(let url):
            return try frames(url, json: json)
        case .live(let target):
            return try inspectLive(.init(kind: .frames, target: target, json: json))
        }
    }

    public static func frame(
        reference: String,
        source: InspectionSource,
        changedOnly: Bool,
        json: Bool
    ) throws -> String {
        switch source {
        case .recording(let url):
            return try frame(
                reference: reference,
                requestedURL: url,
                changedOnly: changedOnly,
                json: json
            )
        case .live(let target):
            return try inspectLive(.init(
                kind: .frame,
                target: target,
                reference: reference,
                changedOnly: changedOnly,
                json: json
            ))
        }
    }

    public static func events(
        _ source: InspectionSource,
        limit: Int,
        json: Bool
    ) throws -> String {
        switch source {
        case .recording(let url):
            return try events(url, limit: limit, json: json)
        case .live(let target):
            return try inspectLive(.init(kind: .events, target: target, limit: limit, json: json))
        }
    }

    public static func annotations(_ source: InspectionSource, json: Bool) throws -> String {
        switch source {
        case .recording(let url):
            return try annotations(url, json: json)
        case .live(let target):
            return try inspectLive(.init(kind: .annotations, target: target, json: json))
        }
    }

    private static func inspectLive(_ inspection: PabloLiveInspectionRequest) throws -> String {
        let result = try send(PabloControlRequest(
            method: .inspectLive,
            liveInspectionRequest: inspection
        ))
        guard let output = result.output else {
            throw RecordingError.capture("The Pablo app returned no live inspection output.")
        }
        return output
    }

    public static func performLiveAction(_ action: PabloLiveActionRequest) throws -> String {
        let result = try send(PabloControlRequest(
            method: .actLive,
            liveActionRequest: action
        ))
        guard let output = result.output else {
            throw RecordingError.capture("The Pablo app returned no live action result.")
        }
        return output
    }

    public static func inspect(_ requestedURL: URL?) throws -> String {
        let packageURL = try resolveRecording(requestedURL)
        let manifest = try RecordingManifest.load(from: packageURL)
        let inputCount = try RecordingStreamReader.events(
            at: try manifest.fileURL(for: "events", in: packageURL)
        ).count
        let accessibilityCount = try RecordingStreamReader.accessibility(
            at: try manifest.fileURL(for: "accessibility", in: packageURL)
        ).count
        let workspaceCount = try RecordingStreamReader.workspace(
            at: try manifest.fileURL(for: "workspace", in: packageURL)
        ).count
        let summary = SessionSummary(
            manifest: manifest,
            inputEventCount: inputCount,
            workspaceRecordCount: workspaceCount,
            accessibilityRecordCount: accessibilityCount,
            annotationCount: try RecordingAnnotationStore.load(from: packageURL).count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(summary), as: UTF8.self)
    }

    public static func latestRecordingPath() throws -> String {
        try resolveRecording(nil).path
    }

    public static func recordings(json: Bool) throws -> String {
        let urls = try recordingURLs()
        if json {
            return try jsonString(urls.map { url in
                RecordingListEntry(
                    path: url.path,
                    name: url.lastPathComponent,
                    modifiedAt: modificationDate(url)
                )
            })
        }
        guard !urls.isEmpty else { return "No recordings found." }
        return urls.enumerated().map { index, url in
            let marker = index == 0 ? "latest" : "      "
            return "\(marker)  \(url.path)"
        }.joined(separator: "\n")
    }

    public static func frames(_ requestedURL: URL?, json: Bool) throws -> String {
        let recording = try ReplayRecording.load(from: resolveRecording(requestedURL))
        if json {
            return try jsonString(recording.accessibilitySteps)
        }
        guard !recording.accessibilitySteps.isEmpty else { return "No accessibility frames found." }
        return recording.accessibilitySteps.map { step in
            let time = formatTime(recording.videoTime(for: step))
            let truncated = step.truncated ? " truncated" : ""
            return "\(step.reference)  \(time)  \(step.applicationID) \(step.applicationName)  \(step.kind)  \(step.reason)  " +
                "changed=\(step.changedNodes.count) removed=\(step.removedNodeIDs.count) " +
                "nodes=\(step.totalNodeCount)\(truncated)"
        }.joined(separator: "\n")
    }

    public static func frame(
        reference: String,
        requestedURL: URL?,
        changedOnly: Bool,
        json: Bool
    ) throws -> String {
        let recording = try ReplayRecording.load(from: resolveRecording(requestedURL))
        let index = try frameIndex(reference)
        guard recording.accessibilitySteps.indices.contains(index) else {
            throw RecordingError.usage(
                "Frame \(reference) does not exist; this recording has " +
                "\(recording.accessibilitySteps.count) accessibility frames."
            )
        }
        let step = recording.accessibilitySteps[index]
        if json {
            return try jsonString(step)
        }
        let nodes = changedOnly ? step.changedNodes : step.nodes
        var lines = [
            "\(step.reference)  \(formatTime(recording.videoTime(for: step)))  \(step.applicationID) \(step.applicationName)  \(step.kind)  \(step.reason)",
            "nodes=\(step.totalNodeCount) changed=\(step.changedNodes.count) " +
                "removed=\(step.removedNodeIDs.count) truncated=\(step.truncated)",
            changedOnly ? "Changed accessibility nodes:" : "Accessibility tree:",
        ]
        lines.append(contentsOf: nodes.map(formatNode))
        if !step.removedNodeIDs.isEmpty {
            lines.append("Removed nodes:")
            lines.append(contentsOf: step.removedNodeIDs.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    public static func events(_ requestedURL: URL?, limit: Int, json: Bool) throws -> String {
        let packageURL = try resolveRecording(requestedURL)
        let manifest = try RecordingManifest.load(from: packageURL)
        let url = try manifest.fileURL(for: "events", in: packageURL)
        let records = try RecordingStreamReader.events(at: url)
        let limited = Array(records.prefix(limit))
        if json {
            return try jsonString(limited)
        }
        guard !limited.isEmpty else { return "No input events found." }
        var lines = limited.enumerated().map { index, event in
            var details: [String] = []
            if let action = event.automationAction {
                details.append("action=\(action.kind.rawValue)")
                details.append("phase=\(action.phase.rawValue)")
                details.append("id=\(action.actionID.uuidString)")
                details.append("caller=\(quoted(action.caller.displayName))")
                if let developerName = action.caller.developerName {
                    details.append("developer=\(quoted(developerName))")
                }
                if let nodeID = action.nodeID { details.append("node=\(nodeID)") }
                if let textLength = action.textLength { details.append("characters=\(textLength)") }
            }
            if let text = event.text { details.append("text=\(quoted(text))") }
            if let applicationID = event.applicationID { details.append("app=\(applicationID)") }
            if let windowID = event.windowID { details.append("window=\(windowID)") }
            if let keyCode = event.keyCode { details.append("key=\(keyCode)") }
            if let x = event.x, let y = event.y {
                details.append(String(format: "at=(%.1f,%.1f)", x, y))
            }
            return String(format: "EVT-%04d  %@  %@%@", index + 1, formatTimeNs(event.timestampNs), event.type,
                          details.isEmpty ? "" : "  " + details.joined(separator: " "))
        }
        if records.count > limited.count {
            lines.append("… \(records.count - limited.count) more events; use --limit \(records.count) to show all")
        }
        return lines.joined(separator: "\n")
    }

    public static func workspace(_ requestedURL: URL?, json: Bool) throws -> String {
        let packageURL = try resolveRecording(requestedURL)
        let manifest = try RecordingManifest.load(from: packageURL)
        let records = try RecordingStreamReader.workspace(
            at: try manifest.fileURL(for: "workspace", in: packageURL)
        )
        if json { return try jsonString(records) }
        guard !records.isEmpty else { return "No workspace snapshots found." }
        return records.enumerated().map { index, record in
            let frontmost = record.frontmostApplicationID ?? "none"
            let appeared = (record.appearedApplicationIDs + record.appearedWindowIDs).joined(separator: ",")
            let removed = (record.removedApplicationIDs + record.removedWindowIDs).joined(separator: ",")
            return String(format: "WKS-%04d  %@  frontmost=%@ apps=%d windows=%d%@%@",
                          index + 1, formatTimeNs(record.timestampNs), frontmost,
                          record.applications.count, record.windows.count,
                          appeared.isEmpty ? "" : " appeared=\(appeared)",
                          removed.isEmpty ? "" : " removed=\(removed)")
        }.joined(separator: "\n")
    }

    public static func annotations(_ requestedURL: URL?, json: Bool) throws -> String {
        let packageURL = try resolveRecording(requestedURL)
        let recording = try ReplayRecording.load(from: packageURL)
        let annotations = recording.annotations
        if json { return try jsonString(annotations) }
        guard !annotations.isEmpty else { return "No annotations found." }
        return annotations.map { annotation in
            let time = annotation.startTimestampNs
                .map { formatTime(recording.videoTime(forTimestampNs: $0)) }
                ?? "--:--.---"
            let frames = annotation.accessibilityReferences.isEmpty
                ? ""
                : "  " + annotation.accessibilityReferences.joined(separator: ",")
            return "\(annotation.reference)  \(time)  \(annotation.status.rawValue)  " +
                "\(annotation.kind.rawValue)\(frames)  \(annotation.text)"
        }.joined(separator: "\n")
    }

    private struct ParsedRecordingArguments {
        var url: URL?
        var json = false
        var changed = false
        var limit: Int?
    }

    private struct ParsedInspectionArguments {
        var url: URL?
        var pid: pid_t?
        var bundleIdentifier: String?
        var appName: String?
        var json = false
        var changed = false
        var limit: Int?

        var source: InspectionSource {
            if pid != nil || bundleIdentifier != nil || appName != nil {
                return .live(PabloLiveApplicationTarget(
                    pid: pid,
                    bundleIdentifier: bundleIdentifier,
                    appName: appName
                ))
            }
            return .recording(url)
        }
    }

    private struct RecordingListEntry: Codable {
        let path: String
        let name: String
        let modifiedAt: Date
    }

    private struct ParsedLiveAction {
        var pid: pid_t?
        var bundleIdentifier: String?
        var appName: String?
        var nodeID: String?
        var point: PabloLivePoint?
        var fromNodeID: String?
        var fromPoint: PabloLivePoint?
        var toNodeID: String?
        var toPoint: PabloLivePoint?
        var mouseButton: PabloLiveMouseButton = .left
        var clickCount = 1
        var duration: TimeInterval = 0.5
        var scrollDirection: PabloLiveScrollDirection?
        var scrollAmount = 3
        var text: String?
        var key: String?
        var modifiers: [PabloLiveKeyModifier] = []
        var accessibilityAction: String?

        var target: PabloLiveApplicationTarget {
            PabloLiveApplicationTarget(
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                appName: appName
            )
        }
    }

    private static func parseLiveAction(
        _ kind: PabloLiveActionKind,
        arguments: [String]
    ) throws -> PabloLiveActionRequest {
        var parsed = ParsedLiveAction()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--pid":
                let value = try next(arguments, &index, option: argument)
                guard let pid = pid_t(value), pid > 0 else {
                    throw RecordingError.usage("--pid must be a positive process ID.")
                }
                parsed.pid = pid
            case "--bundle-id":
                parsed.bundleIdentifier = try next(arguments, &index, option: argument)
            case "--app":
                parsed.appName = try next(arguments, &index, option: argument)
            case "--node" where [.click, .scroll, .typeText, .perform].contains(kind):
                parsed.nodeID = try next(arguments, &index, option: argument)
            case "--point" where [.click, .scroll].contains(kind):
                parsed.point = try livePoint(try next(arguments, &index, option: argument), option: argument)
            case "--from" where kind == .drag:
                parsed.fromPoint = try livePoint(try next(arguments, &index, option: argument), option: argument)
            case "--from-node" where kind == .drag:
                parsed.fromNodeID = try next(arguments, &index, option: argument)
            case "--to" where kind == .drag:
                parsed.toPoint = try livePoint(try next(arguments, &index, option: argument), option: argument)
            case "--to-node" where kind == .drag:
                parsed.toNodeID = try next(arguments, &index, option: argument)
            case "--button" where kind == .click || kind == .drag:
                let value = try next(arguments, &index, option: argument).lowercased()
                guard let button = PabloLiveMouseButton(rawValue: value) else {
                    throw RecordingError.usage("--button must be left, right, or middle.")
                }
                parsed.mouseButton = button
            case "--count" where kind == .click:
                let value = try next(arguments, &index, option: argument)
                guard let count = Int(value), (1...3).contains(count) else {
                    throw RecordingError.usage("--count must be between 1 and 3.")
                }
                parsed.clickCount = count
            case "--duration" where kind == .drag:
                let value = try next(arguments, &index, option: argument)
                guard let duration = TimeInterval(value), duration.isFinite,
                      (0.05...10).contains(duration) else {
                    throw RecordingError.usage("--duration must be from 0.05 to 10 seconds.")
                }
                parsed.duration = duration
            case "--direction" where kind == .scroll:
                let value = try next(arguments, &index, option: argument).lowercased()
                guard let direction = PabloLiveScrollDirection(rawValue: value) else {
                    throw RecordingError.usage("--direction must be up, down, left, or right.")
                }
                parsed.scrollDirection = direction
            case "--amount" where kind == .scroll:
                let value = try next(arguments, &index, option: argument)
                guard let amount = Int(value), (1...100).contains(amount) else {
                    throw RecordingError.usage("--amount must be between 1 and 100.")
                }
                parsed.scrollAmount = amount
            case "--text" where kind == .typeText:
                parsed.text = try next(arguments, &index, option: argument)
            case "--key" where kind == .key:
                parsed.key = try next(arguments, &index, option: argument)
            case "--modifiers" where kind == .key:
                parsed.modifiers = try liveModifiers(
                    try next(arguments, &index, option: argument)
                )
            case "--action" where kind == .perform:
                parsed.accessibilityAction = try next(arguments, &index, option: argument)
            default:
                throw RecordingError.usage("Unknown or inapplicable option for \(kind.rawValue): \(argument)")
            }
            index += 1
        }

        let targetCount = [
            parsed.pid != nil,
            parsed.bundleIdentifier != nil,
            parsed.appName != nil,
        ].filter { $0 }.count
        guard targetCount == 1 else {
            throw RecordingError.usage(
                "Choose exactly one live target with --app, --bundle-id, or --pid."
            )
        }

        switch kind {
        case .click:
            guard (parsed.nodeID == nil) != (parsed.point == nil) else {
                throw RecordingError.usage("click requires exactly one of --node or --point.")
            }
        case .drag:
            guard (parsed.fromNodeID == nil) != (parsed.fromPoint == nil),
                  (parsed.toNodeID == nil) != (parsed.toPoint == nil) else {
                throw RecordingError.usage(
                    "drag requires one --from/--from-node and one --to/--to-node."
                )
            }
        case .scroll:
            guard parsed.scrollDirection != nil else {
                throw RecordingError.usage("scroll requires --direction.")
            }
            guard parsed.nodeID == nil || parsed.point == nil else {
                throw RecordingError.usage("scroll accepts either --node or --point, not both.")
            }
        case .typeText:
            guard let text = parsed.text, !text.isEmpty else {
                throw RecordingError.usage("type requires nonempty --text.")
            }
            guard text.utf8.count <= 32 * 1_024 else {
                throw RecordingError.usage("--text must be at most 32 KiB.")
            }
        case .key:
            guard let key = parsed.key, !key.isEmpty else {
                throw RecordingError.usage("key requires --key.")
            }
        case .perform:
            guard let nodeID = parsed.nodeID, !nodeID.isEmpty,
                  let action = parsed.accessibilityAction, !action.isEmpty else {
                throw RecordingError.usage("perform requires --node and --action.")
            }
        }

        return PabloLiveActionRequest(
            kind: kind,
            target: parsed.target,
            nodeID: parsed.nodeID,
            point: parsed.point,
            fromNodeID: parsed.fromNodeID,
            fromPoint: parsed.fromPoint,
            toNodeID: parsed.toNodeID,
            toPoint: parsed.toPoint,
            mouseButton: parsed.mouseButton,
            clickCount: parsed.clickCount,
            duration: parsed.duration,
            scrollDirection: parsed.scrollDirection,
            scrollAmount: parsed.scrollAmount,
            text: parsed.text,
            key: parsed.key,
            modifiers: parsed.modifiers,
            accessibilityAction: parsed.accessibilityAction
        )
    }

    private static func livePoint(_ value: String, option: String) throws -> PabloLivePoint {
        let parts = try normalizedComponents(value, count: 2, option: "\(option) X,Y")
        return PabloLivePoint(x: parts[0], y: parts[1])
    }

    private static func liveModifiers(_ value: String) throws -> [PabloLiveKeyModifier] {
        guard !value.isEmpty else { return [] }
        var result: [PabloLiveKeyModifier] = []
        for raw in value.split(separator: ",", omittingEmptySubsequences: false) {
            guard let modifier = PabloLiveKeyModifier(rawValue: raw.lowercased()) else {
                throw RecordingError.usage(
                    "--modifiers values must be command, option, control, shift, or function."
                )
            }
            if !result.contains(modifier) { result.append(modifier) }
        }
        return result
    }

    private static func parseInspectionArguments(
        _ arguments: [String],
        allowsChanged: Bool = false,
        allowsLimit: Bool = false
    ) throws -> ParsedInspectionArguments {
        var result = ParsedInspectionArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                result.json = true
            case "--changed" where allowsChanged:
                result.changed = true
            case "--limit" where allowsLimit:
                let value = try next(arguments, &index, option: argument)
                guard let limit = Int(value), limit > 0 else {
                    throw RecordingError.usage("--limit must be a positive integer.")
                }
                result.limit = limit
            case "--pid":
                let value = try next(arguments, &index, option: argument)
                guard let pid = pid_t(value), pid > 0 else {
                    throw RecordingError.usage("--pid must be a positive process ID.")
                }
                result.pid = pid
            case "--bundle-id":
                result.bundleIdentifier = try next(arguments, &index, option: argument)
            case "--app":
                result.appName = try next(arguments, &index, option: argument)
            default:
                if argument.hasPrefix("--") {
                    throw RecordingError.usage("Unknown option: \(argument)")
                }
                guard result.url == nil else {
                    throw RecordingError.usage("Choose only one recording package.")
                }
                result.url = URL(fileURLWithPath: argument)
            }
            index += 1
        }

        let liveSelectorCount = [
            result.pid != nil,
            result.bundleIdentifier != nil,
            result.appName != nil,
        ].filter { $0 }.count
        guard liveSelectorCount <= 1 else {
            throw RecordingError.usage("Choose only one live target with --app, --bundle-id, or --pid.")
        }
        guard result.url == nil || liveSelectorCount == 0 else {
            throw RecordingError.usage("Choose either a recording package or a live target, not both.")
        }
        return result
    }

    private static func parseRecordingArguments(
        _ arguments: [String],
        allowsURL: Bool = true,
        allowsChanged: Bool = false,
        allowsLimit: Bool = false
    ) throws -> ParsedRecordingArguments {
        var result = ParsedRecordingArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                result.json = true
            case "--changed" where allowsChanged:
                result.changed = true
            case "--limit" where allowsLimit:
                index += 1
                guard index < arguments.count,
                      let limit = Int(arguments[index]),
                      limit > 0 else {
                    throw RecordingError.usage("--limit must be a positive integer.")
                }
                result.limit = limit
            default:
                if argument.hasPrefix("--") {
                    throw RecordingError.usage("Unknown option: \(argument)")
                }
                guard allowsURL else {
                    throw RecordingError.usage("Unexpected argument: \(argument)")
                }
                guard result.url == nil else {
                    throw RecordingError.usage("Choose only one recording package.")
                }
                result.url = URL(fileURLWithPath: argument)
            }
            index += 1
        }
        return result
    }

    private static func parseAnnotationOptions(_ arguments: [String]) throws -> AnnotationOptions {
        var options = AnnotationOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--text":
                options.text = try next(arguments, &index, option: argument)
            case "--kind":
                let value = try next(arguments, &index, option: argument)
                guard let kind = RecordingAnnotationKind(rawValue: value.lowercased()) else {
                    throw RecordingError.usage(
                        "--kind must be issue, observation, question, or highlight."
                    )
                }
                options.kind = kind
            case "--at":
                options.at = try annotationTime(arguments, &index, option: argument)
            case "--from":
                options.from = try annotationTime(arguments, &index, option: argument)
            case "--to":
                options.to = try annotationTime(arguments, &index, option: argument)
            case "--frame":
                options.accessibilityReferences.append(try next(arguments, &index, option: argument))
            case "--application":
                options.applicationIDs.append(try next(arguments, &index, option: argument).uppercased())
            case "--node":
                options.accessibilityNodeIDs.append(try next(arguments, &index, option: argument))
            case "--point":
                options.point = try annotationPoint(try next(arguments, &index, option: argument))
            case "--trace":
                options.tracePoints.append(
                    try annotationTracePoint(try next(arguments, &index, option: argument))
                )
            case "--line-width":
                let value = try next(arguments, &index, option: argument)
                guard let width = Double(value), width.isFinite, width > 0, width <= 0.1 else {
                    throw RecordingError.usage("--line-width must be greater than zero and at most 0.1.")
                }
                options.lineWidth = width
            default:
                if argument.hasPrefix("--") {
                    throw RecordingError.usage("Unknown option: \(argument)")
                }
                guard options.recordingURL == nil else {
                    throw RecordingError.usage("Choose only one recording package.")
                }
                options.recordingURL = URL(fileURLWithPath: argument)
            }
            index += 1
        }
        guard let text = options.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecordingError.usage("--text is required and cannot be empty.")
        }
        if options.at != nil && (options.from != nil || options.to != nil) {
            throw RecordingError.usage("Use either --at or --from/--to, not both.")
        }
        if (options.from == nil) != (options.to == nil) {
            throw RecordingError.usage("--from and --to must be used together.")
        }
        if let from = options.from, let to = options.to, to < from {
            throw RecordingError.usage("--to cannot precede --from.")
        }
        if !options.tracePoints.isEmpty &&
            (options.point != nil || options.at != nil || options.from != nil || options.to != nil) {
            throw RecordingError.usage(
                "Timed --trace samples cannot be combined with --point, --at, or --from/--to."
            )
        }
        if options.point != nil && options.at == nil && options.from == nil {
            throw RecordingError.usage("--point requires --at or --from/--to.")
        }
        if !zip(options.tracePoints, options.tracePoints.dropFirst()).allSatisfy({
            $0.videoTime <= $1.videoTime
        }) {
            throw RecordingError.usage("--trace samples must be ordered by time.")
        }
        return options
    }

    private static func annotationTime(
        _ arguments: [String],
        _ index: inout Int,
        option: String
    ) throws -> TimeInterval {
        let value = try next(arguments, &index, option: option)
        guard let time = TimeInterval(value), time.isFinite, time >= 0 else {
            throw RecordingError.usage("\(option) must be a nonnegative number of seconds.")
        }
        return time
    }

    private static func annotationPoint(_ value: String) throws -> AnnotationPoint {
        let parts = try normalizedComponents(value, count: 2, option: "--point X,Y")
        return AnnotationPoint(x: parts[0], y: parts[1])
    }

    private static func annotationTracePoint(_ value: String) throws -> AnnotationTracePoint {
        let rawParts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard rawParts.count == 3,
              let time = TimeInterval(rawParts[0]), time.isFinite, time >= 0 else {
            throw RecordingError.usage(
                "--trace must look like SEC,X,Y with a nonnegative time and normalized coordinates."
            )
        }
        let coordinates = try normalizedComponents(
            rawParts.dropFirst().map(String.init).joined(separator: ","),
            count: 2,
            option: "--trace SEC,X,Y"
        )
        return AnnotationTracePoint(videoTime: time, x: coordinates[0], y: coordinates[1])
    }

    private static func normalizedComponents(
        _ value: String,
        count: Int,
        option: String
    ) throws -> [Double] {
        let rawParts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard rawParts.count == count else {
            throw RecordingError.usage("\(option) requires normalized values separated by commas.")
        }
        let parts = rawParts.compactMap { Double($0) }
        guard parts.count == count,
              parts.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw RecordingError.usage("\(option) values must be normalized from zero to one.")
        }
        return parts
    }

    private static func resolveRecording(_ requestedURL: URL?) throws -> URL {
        let url: URL
        if let requestedURL {
            url = requestedURL
        } else {
            guard let latest = try recordingURLs().first else {
                throw RecordingError.usage("No recordings found in \(recordingsDirectory.path).")
            }
            url = latest
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(
                atPath: url.appendingPathComponent("manifest.json").path
              ) else {
            throw RecordingError.usage("Not a Pablo recording package: \(url.path)")
        }
        return url
    }

    private static func recordingURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.pathExtension == "pablo" &&
                ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
        .sorted { modificationDate($0) > modificationDate($1) }
    }

    private static var recordingsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("Pablo Recordings", isDirectory: true)
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func frameIndex(_ reference: String) throws -> Int {
        var value = reference.uppercased()
        if value.hasPrefix("A11Y-") { value.removeFirst(5) }
        if value.hasPrefix("#") { value.removeFirst() }
        guard let number = Int(value), number > 0 else {
            throw RecordingError.usage("Frame must look like A11Y-012 or 12.")
        }
        return number - 1
    }

    private static func accessibilityStep(
        _ reference: String,
        in recording: ReplayRecording
    ) throws -> ReplayAccessibilityStep {
        let index = try frameIndex(reference)
        guard recording.accessibilitySteps.indices.contains(index) else {
            throw RecordingError.usage("Frame \(reference) does not exist.")
        }
        return recording.accessibilitySteps[index]
    }

    private static func formatNode(_ node: ReplayAccessibilityNode) -> String {
        let indentation = String(repeating: "  ", count: min(node.depth, 20))
        let role = node.role ?? "UnknownRole"
        let value = [node.title, node.label, node.value]
            .compactMap { $0 }
            .first { !$0.isEmpty }
            .map { " \(quoted($0))" } ?? ""
        let focused = node.focused == true ? " focused" : ""
        return "\(indentation)- \(role)\(value) [\(node.id)]\(focused)"
    }

    private static func quoted(_ value: String) -> String {
        String(reflecting: value)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        return String(
            format: "%02d:%06.3f",
            Int(clamped) / 60,
            clamped.truncatingRemainder(dividingBy: 60)
        )
    }

    private static func formatTimeNs(_ nanoseconds: UInt64) -> String {
        formatTime(TimeInterval(nanoseconds) / 1_000_000_000)
    }

    private static func jsonString<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func next(_ arguments: [String], _ index: inout Int, option: String) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw RecordingError.usage("Missing value for \(option).")
        }
        return arguments[index]
    }

    private static func requireNoArguments(_ arguments: [String], usage: String) throws {
        guard arguments.count == 1 else { throw RecordingError.usage("Usage: \(usage)") }
    }

    private static func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-gj", "-b", "com.ramon.pablo"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RecordingError.capture(
                "Could not launch Pablo. Install and open Pablo.app once, then try again."
            )
        }
    }

    private static func waitForAppAndSend(_ request: PabloControlRequest) throws -> PabloControlResponse {
        var lastError: Error?
        for _ in 0..<80 {
            do {
                return try PabloControlClient.send(request)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastError ?? RecordingError.capture("Pablo did not start its control service.")
    }

}
