import ApplicationServices
import Foundation

public struct RecordOptions {
    public var pid: pid_t?
    public var bundleIdentifier: String?
    public var appName: String?
    public var outputURL: URL?
    public var duration: TimeInterval?
    public var snapshotInterval: TimeInterval = 1
    public var captureText = true
    public var framesPerSecond = 30

    public init() {}
}

public enum Command {
    case record(RecordOptions)
    case status
    case pause
    case resume
    case stop
    case inspect(URL?)
    case latest
    case recordings(json: Bool)
    case frames(URL?, json: Bool)
    case frame(reference: String, recording: URL?, changedOnly: Bool, json: Bool)
    case events(URL?, limit: Int, json: Bool)
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
            guard selectors == 1 else {
                throw RecordingError.usage("Choose exactly one target with --app, --bundle-id, or --pid.")
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
            let parsed = try parseRecordingArguments(Array(arguments.dropFirst()))
            return .inspect(parsed.url)
        case "latest":
            guard arguments.count == 1 else {
                throw RecordingError.usage("Usage: pablo latest")
            }
            return .latest
        case "recordings", "list":
            let parsed = try parseRecordingArguments(Array(arguments.dropFirst()), allowsURL: false)
            return .recordings(json: parsed.json)
        case "frames":
            let parsed = try parseRecordingArguments(Array(arguments.dropFirst()))
            return .frames(parsed.url, json: parsed.json)
        case "frame":
            guard arguments.count >= 2 else {
                throw RecordingError.usage("Usage: pablo frame <A11Y-###> [recording.pablo] [--changed] [--json]")
            }
            let reference = arguments[1]
            let parsed = try parseRecordingArguments(
                Array(arguments.dropFirst(2)),
                allowsChanged: true
            )
            return .frame(
                reference: reference,
                recording: parsed.url,
                changedOnly: parsed.changed,
                json: parsed.json
            )
        case "events":
            let parsed = try parseRecordingArguments(Array(arguments.dropFirst()), allowsLimit: true)
            return .events(parsed.url, limit: parsed.limit ?? 100, json: parsed.json)
        case "help", "--help", "-h":
            return .help
        default:
            throw RecordingError.usage("Unknown command: \(command)")
        }
    }

    public static let help = """
    Usage:
      pablo record (--app NAME | --bundle-id ID | --pid PID) [options]
      pablo status
      pablo pause
      pablo resume
      pablo stop
      pablo recordings [--json]
      pablo latest
      pablo inspect [recording.pablo]
      pablo frames [recording.pablo] [--json]
      pablo frame <A11Y-###> [recording.pablo] [--changed] [--json]
      pablo events [recording.pablo] [--limit N] [--json]

    Record options:
      -o, --output PATH          Output package (default: ~/Movies/Pablo Recordings)
      --duration SECONDS        Stop automatically; otherwise use pablo stop
      --snapshot-interval SEC   Periodic accessibility snapshot interval (default: 1)
      --fps FPS                 Video frame rate from 1 to 60 (default: 30)
      --no-text                 Keep key codes but omit typed Unicode text

    Example:
      pablo record --app Notes --duration 20 -o notes-session.pablo

    Recording controls are sent to the Pablo app and require daily approval per calling application.
    Replay commands default to the latest recording in ~/Movies/Pablo Recordings.
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
        var parts = [result.state]
        if let target = result.target { parts.append(target) }
        parts.append(formatTimeNs(result.elapsedNanoseconds))
        if let recordingPath = result.recordingPath { parts.append(recordingPath) }
        return parts.joined(separator: "  ")
    }

    public static func inspect(_ requestedURL: URL?) throws -> String {
        let packageURL = try resolveRecording(requestedURL)
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
        let inputCount = try lineCount(packageURL.appendingPathComponent(manifest.files["events"] ?? "events.jsonl"))
        let accessibilityCount = try lineCount(
            packageURL.appendingPathComponent(manifest.files["accessibility"] ?? "accessibility.jsonl")
        )
        let summary = SessionSummary(
            manifest: manifest,
            inputEventCount: inputCount,
            accessibilityRecordCount: accessibilityCount
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
            return "\(step.reference)  \(time)  \(step.kind)  \(step.reason)  " +
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
            "\(step.reference)  \(formatTime(recording.videoTime(for: step)))  \(step.kind)  \(step.reason)",
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
        let manifest = try JSONDecoder().decode(
            RecordingManifest.self,
            from: Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))
        )
        let url = packageURL.appendingPathComponent(manifest.files["events"] ?? "events.jsonl")
        let records: [InputEventRecord] = try decodeJSONLines(at: url)
        let limited = Array(records.prefix(limit))
        if json {
            return try jsonString(limited)
        }
        guard !limited.isEmpty else { return "No input events found." }
        var lines = limited.enumerated().map { index, event in
            var details: [String] = []
            if let text = event.text { details.append("text=\(quoted(text))") }
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

    private struct ParsedRecordingArguments {
        var url: URL?
        var json = false
        var changed = false
        var limit: Int?
    }

    private struct RecordingListEntry: Codable {
        let path: String
        let name: String
        let modifiedAt: Date
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

    private static func decodeJSONLines<Value: Decodable>(at url: URL) throws -> [Value] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).map { line in
            try decoder.decode(Value.self, from: Data(line))
        }
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

    private static func lineCount(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }
}
