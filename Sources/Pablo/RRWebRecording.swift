import Foundation

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
    public static let schemaVersion = 1

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

public enum PabloRRWebRecordingStorage {
    public static let packageExtension = "pabloweb"
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
        let packageURL = uniquePackageURL(tabTitle: tab.title, date: date, directory: directory, fileManager: fileManager)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
        let recording = PabloRRWebRecording(
            packageURL: packageURL,
            manifest: PabloRRWebRecordingManifest(recordingID: recordingID, tab: tab, startedAt: date),
            eventsURL: packageURL.appendingPathComponent(eventsFilename)
        )
        do {
            try writeManifest(recording.manifest, to: packageURL)
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
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        let manifest = try decoder.decode(PabloRRWebRecordingManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == PabloRRWebRecordingManifest.schemaVersion else {
            throw RecordingError.capture("Unsupported rrweb recording schema \(manifest.schemaVersion).")
        }
        let eventsURL = packageURL.appendingPathComponent(eventsFilename)
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
        try writeManifest(manifest, to: packageURL)
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
                    wroteEvent = true
                    eventCount += 1
                }
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
        try writeManifest(manifest, to: packageURL)
        recording = PabloRRWebRecording(packageURL: packageURL, manifest: manifest, eventsURL: recording.eventsURL)
        return recording
    }

    private static func writeManifest(_ manifest: PabloRRWebRecordingManifest, to packageURL: URL) throws {
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent(manifestFilename),
            options: .atomic
        )
    }

    private static func uniquePackageURL(
        tabTitle: String,
        date: Date,
        directory: URL,
        fileManager: FileManager
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let title = safeFilenameComponent(tabTitle) ?? "Safari Tab"
        let base = "\(title) Web Recording \(formatter.string(from: date))"
        var candidate = directory.appendingPathComponent("\(base).\(packageExtension)", isDirectory: true)
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

    private static func safeFilenameComponent(_ value: String) -> String? {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        let replaced = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return forbidden.contains(scalar) ? "-" : String(scalar)
        }.joined()
        let collapsed = replaced.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : String(collapsed.prefix(80))
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
