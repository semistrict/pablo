import Foundation

private func rrwebNanoseconds(milliseconds: Double) throws -> UInt64 {
    let nanoseconds = milliseconds * 1_000_000
    guard nanoseconds.isFinite,
          let value = UInt64(exactly: nanoseconds.rounded(.towardZero)) else {
        throw RecordingError.capture("The rrweb recording contains an out-of-range event timestamp.")
    }
    return value
}

public enum PabloRRWebRecordingState: String, Codable, Sendable {
    case recording
    case paused
    case complete
    case interrupted
    case failed
}

public struct PabloSafariTab: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let windowID: Int64?
    public let title: String
    public let url: String

    public init(id: Int64, windowID: Int64? = nil, title: String, url: String) {
        self.id = id
        self.windowID = windowID
        self.title = title
        self.url = url
    }
}

public struct PabloRRWebRecordingManifest: Codable, Sendable {
    public static let schemaVersion = 3

    public let schemaVersion: Int
    public let recordingID: UUID
    public let tab: PabloSafariTab
    public let startedAt: Date
    public var endedAt: Date?
    public var state: PabloRRWebRecordingState
    public var eventCount: Int
    public let inputsMasked: Bool
    public let rrwebVersion: String
    public var error: String?

    public init(
        recordingID: UUID,
        tab: PabloSafariTab,
        startedAt: Date,
        endedAt: Date? = nil,
        state: PabloRRWebRecordingState = .recording,
        eventCount: Int = 0,
        inputsMasked: Bool = true,
        rrwebVersion: String = "2.1.1",
        error: String? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.recordingID = recordingID
        self.tab = tab
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.eventCount = eventCount
        self.inputsMasked = inputsMasked
        self.rrwebVersion = rrwebVersion
        self.error = error
    }
}

public struct PabloRRWebRecording: Sendable {
    public let packageURL: URL
    public let manifest: PabloRRWebRecordingManifest
    public let eventsURL: URL
}

public struct PabloRRWebReplayEvent: Identifiable, Sendable {
    public let index: Int
    public let timestampNs: UInt64
    public let lane: ReplayTimelineLane
    public let title: String
    public let subtitle: String?
    public let importance: ReplayTimelineImportance
    public let formattedJSON: String

    public var id: Int { index }
}

public struct PabloRRWebReplayData: Sendable {
    public let events: [PabloRRWebReplayEvent]
    public let timelineItems: [ReplayTimelineItem]
    public let duration: TimeInterval

    public init(recording: PabloRRWebRecording) throws {
        let data = try Data(contentsOf: recording.eventsURL)
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw RecordingError.capture("The rrweb recording does not contain an event array.")
        }
        let firstTimestamp = objects.compactMap(Self.timestamp).min() ?? 0
        var replayEvents: [PabloRRWebReplayEvent] = []
        replayEvents.reserveCapacity(objects.count)
        for (index, object) in objects.enumerated() {
            let timestamp = Self.timestamp(object) ?? firstTimestamp
            let relativeMilliseconds = max(0, timestamp - firstTimestamp)
            let timestampNs = try rrwebNanoseconds(milliseconds: relativeMilliseconds)
            let description = Self.describe(object)
            let formattedJSON = (try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            replayEvents.append(PabloRRWebReplayEvent(
                index: index,
                timestampNs: timestampNs,
                lane: description.lane,
                title: description.title,
                subtitle: description.subtitle,
                importance: description.importance,
                formattedJSON: formattedJSON
            ))
        }
        events = replayEvents
        timelineItems = replayEvents.map { event in
            ReplayTimelineItem(
                id: "rrweb:\(event.index)",
                lane: event.lane,
                timestampNs: event.timestampNs,
                endTimestampNs: event.timestampNs,
                title: event.title,
                subtitle: event.subtitle,
                applicationIDs: ["SAFARI-TAB-\(recording.manifest.tab.id)"],
                importance: event.importance,
                references: [.rrweb(event.index)]
            )
        }
        duration = max(0.001, TimeInterval(replayEvents.map(\.timestampNs).max() ?? 0) / 1_000_000_000)
    }

    public func event(index: Int) -> PabloRRWebReplayEvent? {
        events.first { $0.index == index }
    }

    public func timelineItems(annotations: [RecordingAnnotation]) -> [ReplayTimelineItem] {
        var items = timelineItems
        for annotation in annotations {
            guard let start = annotation.startTimestampNs ?? annotation.trace?.startTimestampNs else { continue }
            let end = annotation.endTimestampNs ?? annotation.trace?.endTimestampNs ?? start
            items.append(ReplayTimelineItem(
                id: "annotation:\(annotation.id.uuidString)",
                lane: .annotation,
                timestampNs: start,
                endTimestampNs: end,
                title: annotation.text,
                subtitle: annotation.reference,
                applicationIDs: annotation.applicationIDs,
                importance: .meaningful,
                references: [.annotation(annotation.id)]
            ))
        }
        return items.sorted {
            $0.timestampNs == $1.timestampNs
                ? $0.lane.rawValue < $1.lane.rawValue
                : $0.timestampNs < $1.timestampNs
        }
    }

    private static func timestamp(_ object: [String: Any]) -> Double? {
        (object["timestamp"] as? NSNumber)?.doubleValue
    }

    private static func describe(
        _ object: [String: Any]
    ) -> (lane: ReplayTimelineLane, title: String, subtitle: String?, importance: ReplayTimelineImportance) {
        let type = (object["type"] as? NSNumber)?.intValue ?? -1
        let data = object["data"] as? [String: Any] ?? [:]
        switch type {
        case 0:
            return (.document, "DOM ready", nil, .meaningful)
        case 1:
            return (.document, "Page loaded", nil, .meaningful)
        case 2:
            return (.document, "DOM snapshot", "Full document state", .meaningful)
        case 3:
            return describeIncremental(data)
        case 4:
            let url = data["href"] as? String
            return (.workspace, "Page metadata", url, .meaningful)
        case 5:
            let tag = data["tag"] as? String
            return (.document, tag.map { "Custom: \($0)" } ?? "Custom event", nil, .technical)
        case 6:
            return (.document, "Plugin event", nil, .technical)
        default:
            return (.document, "Unknown rrweb event", "Type \(type)", .warning)
        }
    }

    private static func describeIncremental(
        _ data: [String: Any]
    ) -> (lane: ReplayTimelineLane, title: String, subtitle: String?, importance: ReplayTimelineImportance) {
        let source = (data["source"] as? NSNumber)?.intValue ?? -1
        switch source {
        case 0:
            let adds = (data["adds"] as? [Any])?.count ?? 0
            let removes = (data["removes"] as? [Any])?.count ?? 0
            let texts = (data["texts"] as? [Any])?.count ?? 0
            let attributes = (data["attributes"] as? [Any])?.count ?? 0
            let count = adds + removes + texts + attributes
            return (.document, "DOM mutation", count > 0 ? "\(count) changes" : nil, .meaningful)
        case 1, 6, 12:
            return (.input, source == 12 ? "Drag" : "Pointer movement", nil, .technical)
        case 2:
            let interaction = (data["type"] as? NSNumber)?.intValue ?? -1
            let names = [
                0: "Pointer up", 1: "Pointer down", 2: "Click", 3: "Context menu",
                4: "Double click", 5: "Focus", 6: "Blur", 7: "Touch start", 9: "Touch end",
            ]
            return (.input, names[interaction] ?? "Pointer interaction", nil, .meaningful)
        case 3:
            return (.input, "Scroll", nil, .meaningful)
        case 4:
            let width = (data["width"] as? NSNumber)?.intValue
            let height = (data["height"] as? NSNumber)?.intValue
            let size = width.flatMap { width in height.map { "\(width) × \($0)" } }
            return (.document, "Viewport resized", size, .meaningful)
        case 5:
            return (.input, "Input changed", "Value masked", .meaningful)
        case 7:
            return (.input, "Media interaction", nil, .meaningful)
        case 8, 13, 15:
            return (.document, "Style changed", nil, .meaningful)
        case 9:
            return (.document, "Canvas changed", nil, .meaningful)
        case 10:
            return (.document, "Font loaded", nil, .technical)
        case 11:
            return (.document, "Console log", nil, .technical)
        case 14:
            return (.input, "Selection changed", nil, .meaningful)
        case 16:
            return (.document, "Custom element defined", nil, .technical)
        default:
            return (.document, "Incremental event", "Source \(source)", .technical)
        }
    }
}

public enum PabloRRWebRecordingStorage {
    public static let packageExtension = "pablo"
    public static let manifestFilename = "manifest.json"
    public static let eventsFilename = "events.json"

    public static func create(
        recordingID: UUID,
        tab: PabloSafariTab,
        at date: Date = Date(),
        directory: URL = PabloRecordingStorage.localRecordingsDirectory,
        fileManager: FileManager = .default
    ) throws -> PabloRRWebRecording {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let packageURL = uniquePackageURL(date: date, directory: directory, fileManager: fileManager)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
        let recording = PabloRRWebRecording(
            packageURL: packageURL,
            manifest: PabloRRWebRecordingManifest(recordingID: recordingID, tab: tab, startedAt: date),
            eventsURL: packageURL.appendingPathComponent(eventsFilename)
        )
        do {
            try writeUnifiedManifest(recording.manifest, to: packageURL)
            try Data("[]\n".utf8).write(to: recording.eventsURL, options: .atomic)
            return recording
        } catch {
            try? fileManager.removeItem(at: packageURL)
            throw error
        }
    }

    public static func load(_ packageURL: URL) throws -> PabloRRWebRecording {
        guard packageURL.pathExtension.caseInsensitiveCompare(packageExtension) == .orderedSame else {
            throw RecordingError.usage("Expected a .\(packageExtension) recording package.")
        }
        let unified = try RecordingManifest.load(from: packageURL)
        guard unified.dataSource == .rrweb, let web = unified.web else {
            throw RecordingError.usage("The .pablo package does not contain Safari rrweb events.")
        }
        let manifest = PabloRRWebRecordingManifest(
            recordingID: web.recordingID,
            tab: web.tab,
            startedAt: web.startedAt,
            endedAt: web.endedAt,
            state: web.state,
            eventCount: web.eventCount,
            inputsMasked: web.inputsMasked,
            rrwebVersion: web.rrwebVersion,
            error: web.error
        )
        let eventsURL = try unified.fileURL(for: "rrweb", in: packageURL)
        guard FileManager.default.fileExists(atPath: eventsURL.path) else {
            throw RecordingError.capture("The rrweb recording is missing events.json.")
        }
        return PabloRRWebRecording(packageURL: packageURL, manifest: manifest, eventsURL: eventsURL)
    }

    public static func recordings(
        directory: URL = PabloRecordingStorage.localRecordingsDirectory,
        fileManager: FileManager = .default
    ) throws -> [PabloRRWebRecording] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.caseInsensitiveCompare(packageExtension) == .orderedSame }
        .compactMap { try? load($0) }
        .sorted { $0.manifest.startedAt > $1.manifest.startedAt }
    }

    public static func updateState(
        _ state: PabloRRWebRecordingState,
        packageURL: URL,
        endedAt: Date? = nil,
        error: String? = nil
    ) throws -> PabloRRWebRecording {
        var recording = try load(packageURL)
        var manifest = recording.manifest
        manifest.state = state
        manifest.endedAt = endedAt
        manifest.error = error
        try writeUnifiedManifest(manifest, to: packageURL)
        recording = PabloRRWebRecording(packageURL: packageURL, manifest: manifest, eventsURL: recording.eventsURL)
        return recording
    }

    @discardableResult
    public static func finalize(
        packageURL: URL,
        batches: [Data],
        state: PabloRRWebRecordingState = .complete,
        endedAt: Date = Date(),
        error: String? = nil
    ) throws -> PabloRRWebRecording {
        var recording = try load(packageURL)
        let temporaryURL = packageURL.appendingPathComponent("events.json.tmp")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        var eventCount = 0
        var firstEventTimestamp: Double?
        var lastEventTimestamp: Double?
        var eventDurationNs: UInt64?
        do {
            try handle.write(contentsOf: Data("[".utf8))
            var wroteEvent = false
            for batch in batches {
                guard let events = try JSONSerialization.jsonObject(with: batch) as? [Any] else {
                    throw RecordingError.capture("The Safari extension produced an invalid rrweb event batch.")
                }
                for event in events {
                    guard JSONSerialization.isValidJSONObject(event) else {
                        throw RecordingError.capture("The Safari extension produced an invalid rrweb event.")
                    }
                    if wroteEvent { try handle.write(contentsOf: Data(",".utf8)) }
                    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: event))
                    if let object = event as? [String: Any],
                       let timestamp = (object["timestamp"] as? NSNumber)?.doubleValue {
                        firstEventTimestamp = min(firstEventTimestamp ?? timestamp, timestamp)
                        lastEventTimestamp = max(lastEventTimestamp ?? timestamp, timestamp)
                    }
                    wroteEvent = true
                    eventCount += 1
                }
            }
            if let first = firstEventTimestamp, let last = lastEventTimestamp {
                eventDurationNs = try rrwebNanoseconds(milliseconds: max(0, last - first))
            }
            try handle.write(contentsOf: Data("]\n".utf8))
            try handle.close()
            _ = try FileManager.default.replaceItemAt(recording.eventsURL, withItemAt: temporaryURL)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        var manifest = recording.manifest
        manifest.state = state
        manifest.endedAt = endedAt
        manifest.eventCount = eventCount
        manifest.error = error
        try writeUnifiedManifest(manifest, to: packageURL, durationNs: eventDurationNs)
        recording = PabloRRWebRecording(packageURL: packageURL, manifest: manifest, eventsURL: recording.eventsURL)
        return recording
    }

    private static func writeUnifiedManifest(
        _ metadata: PabloRRWebRecordingManifest,
        to packageURL: URL,
        durationNs suppliedDurationNs: UInt64? = nil
    ) throws {
        let existing = try? RecordingManifest.load(from: packageURL)
        let durationNs: UInt64? = if let suppliedDurationNs {
            suppliedDurationNs
        } else if let existingDuration = existing?.durationNs {
            existingDuration
        } else if let endedAt = metadata.endedAt {
            UInt64(max(0, endedAt.timeIntervalSince(metadata.startedAt)) * 1_000_000_000)
        } else {
            nil
        }
        let safariApplication = RecordingApplication(
            id: "SAFARI-TAB-\(metadata.tab.id)",
            pid: 0,
            bundleIdentifier: "com.apple.Safari",
            name: "Safari — \(metadata.tab.title)",
            firstSeenTimestampNs: 0,
            lastSeenTimestampNs: durationNs
        )
        let unified = RecordingManifest(
            schemaVersion: RecordingManifest.currentSchemaVersion,
            dataSource: .rrweb,
            startedAt: ISO8601DateFormatter.recordingFormatter.string(from: metadata.startedAt),
            endedAt: metadata.endedAt.map(ISO8601DateFormatter.recordingFormatter.string),
            durationNs: durationNs,
            scope: .init(
                kind: .application,
                selectedApplicationID: safariApplication.id,
                selectedDisplayID: nil
            ),
            displays: [],
            applications: [safariApplication],
            capture: .init(
                frame: RecordingRect(x: 0, y: 0, width: 0, height: 0),
                displayScale: 1,
                width: 0,
                height: 0,
                framesPerSecond: 0,
                firstFrameTimestampNs: 0,
                videoTracks: []
            ),
            files: ["rrweb": eventsFilename],
            web: .init(
                recordingID: metadata.recordingID,
                tab: metadata.tab,
                startedAt: metadata.startedAt,
                endedAt: metadata.endedAt,
                state: metadata.state,
                eventCount: metadata.eventCount,
                inputsMasked: metadata.inputsMasked,
                rrwebVersion: metadata.rrwebVersion,
                error: metadata.error
            )
        )
        try encoder.encode(unified).write(
            to: packageURL.appendingPathComponent(manifestFilename),
            options: .atomic
        )
    }

    private static func uniquePackageURL(
        date: Date,
        directory: URL,
        fileManager: FileManager
    ) -> URL {
        var candidate = PabloRecordingStorage.defaultRecordingURL(
            applicationName: "Safari", at: date, directory: directory
        )
        let base = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(
                "\(base) \(suffix).\(packageExtension)",
                isDirectory: true
            )
            suffix += 1
        }
        return candidate
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
