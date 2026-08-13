import Foundation

public enum RecordingAnnotationKind: String, Codable, CaseIterable, Sendable {
    case issue
    case observation
    case question
    case highlight
}

public enum RecordingAnnotationStatus: String, Codable, Sendable {
    case open
    case resolved
}

public enum RecordingAnnotationAuthorType: String, Codable, Sendable {
    case human
    case application
}

public struct RecordingAnnotationAuthor: Codable, Equatable, Sendable {
    public let type: RecordingAnnotationAuthorType
    public let displayName: String
    public let applicationIdentifier: String?
    public let developerName: String?
    public let developerTeamIdentifier: String?

    public init(
        type: RecordingAnnotationAuthorType,
        displayName: String,
        applicationIdentifier: String? = nil,
        developerName: String? = nil,
        developerTeamIdentifier: String? = nil
    ) {
        self.type = type
        self.displayName = displayName
        self.applicationIdentifier = applicationIdentifier
        self.developerName = developerName
        self.developerTeamIdentifier = developerTeamIdentifier
    }

    public static let localHuman = RecordingAnnotationAuthor(
        type: .human,
        displayName: "Human reviewer"
    )
}

public struct RecordingAnnotationTraceSample: Codable, Equatable, Sendable {
    public let timestampNs: UInt64
    public let x: Double
    public let y: Double

    public init(timestampNs: UInt64, x: Double, y: Double) {
        self.timestampNs = timestampNs
        self.x = x
        self.y = y
    }

    fileprivate var isValid: Bool {
        [x, y].allSatisfy(\.isFinite) &&
            (0...1).contains(x) && (0...1).contains(y)
    }
}

/// A freehand path through normalized video space and session time.
/// Equal timestamps represent a shape drawn while the video was paused.
public struct RecordingAnnotationTrace: Codable, Equatable, Sendable {
    public let samples: [RecordingAnnotationTraceSample]
    public let lineWidth: Double

    public init(samples: [RecordingAnnotationTraceSample], lineWidth: Double = 0.008) {
        self.samples = samples
        self.lineWidth = lineWidth
    }

    public var startTimestampNs: UInt64? { samples.first?.timestampNs }
    public var endTimestampNs: UInt64? { samples.last?.timestampNs }

    /// Returns the portion of the trace visible at a point on the session timeline.
    /// A paused trace (all timestamps equal) appears as one complete shape. A moving
    /// trace is revealed in order, with an interpolated tip between captured samples.
    public func visibleSamples(
        at timestampNs: UInt64,
        pointToleranceNs: UInt64,
        tailDurationNs: UInt64 = 0
    ) -> [RecordingAnnotationTraceSample] {
        guard let first = samples.first, let last = samples.last else { return [] }
        if first.timestampNs == last.timestampNs {
            let distance = timestampNs >= first.timestampNs
                ? timestampNs - first.timestampNs
                : first.timestampNs - timestampNs
            return distance <= pointToleranceNs ? samples : []
        }
        guard timestampNs >= first.timestampNs else { return [] }
        let tailEnd = last.timestampNs.addingReportingOverflow(tailDurationNs)
        if !tailEnd.overflow, timestampNs > tailEnd.partialValue { return [] }
        if timestampNs >= last.timestampNs { return samples }

        var visible = Array(samples.prefix { $0.timestampNs <= timestampNs })
        guard let before = visible.last,
              let after = samples.first(where: { $0.timestampNs > timestampNs }),
              after.timestampNs > before.timestampNs else { return visible }
        let progress = Double(timestampNs - before.timestampNs) /
            Double(after.timestampNs - before.timestampNs)
        visible.append(RecordingAnnotationTraceSample(
            timestampNs: timestampNs,
            x: before.x + (after.x - before.x) * progress,
            y: before.y + (after.y - before.y) * progress
        ))
        return visible
    }

    fileprivate var isValid: Bool {
        guard !samples.isEmpty,
              lineWidth.isFinite,
              lineWidth > 0,
              lineWidth <= 0.1,
              samples.allSatisfy(\.isValid) else { return false }
        return zip(samples, samples.dropFirst()).allSatisfy {
            $0.timestampNs <= $1.timestampNs
        }
    }
}

public struct RecordingAnnotationDraft: Codable, Equatable, Sendable {
    public let kind: RecordingAnnotationKind
    public let text: String
    public let startTimestampNs: UInt64?
    public let endTimestampNs: UInt64?
    public let applicationIDs: [String]
    public let accessibilityReferences: [String]
    public let accessibilityNodeIDs: [String]
    public let trace: RecordingAnnotationTrace?

    public init(
        kind: RecordingAnnotationKind,
        text: String,
        startTimestampNs: UInt64? = nil,
        endTimestampNs: UInt64? = nil,
        applicationIDs: [String] = [],
        accessibilityReferences: [String] = [],
        accessibilityNodeIDs: [String] = [],
        trace: RecordingAnnotationTrace? = nil
    ) {
        self.kind = kind
        self.text = text
        self.startTimestampNs = startTimestampNs
        self.endTimestampNs = endTimestampNs
        self.applicationIDs = applicationIDs
        self.accessibilityReferences = accessibilityReferences
        self.accessibilityNodeIDs = accessibilityNodeIDs
        self.trace = trace
    }
}

public struct RecordingAnnotation: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sequence: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let createdBy: RecordingAnnotationAuthor
    public let updatedBy: RecordingAnnotationAuthor
    public let kind: RecordingAnnotationKind
    public let status: RecordingAnnotationStatus
    public let text: String
    public let startTimestampNs: UInt64?
    public let endTimestampNs: UInt64?
    public let applicationIDs: [String]
    public let accessibilityReferences: [String]
    public let accessibilityNodeIDs: [String]
    public let trace: RecordingAnnotationTrace?

    public var reference: String {
        String(format: "NOTE-%03d", sequence)
    }
}

public enum RecordingAnnotationStore {
    public static let filename = "annotations.pb"
    private static let lock = NSLock()

    public static func load(from packageURL: URL) throws -> [RecordingAnnotation] {
        try lock.withLock {
            try loadUnlocked(from: packageURL)
        }
    }

    public static func add(
        to packageURL: URL,
        draft: RecordingAnnotationDraft,
        author: RecordingAnnotationAuthor,
        now: Date = Date()
    ) throws -> RecordingAnnotation {
        try lock.withLock {
            try validatePackage(packageURL)
            try validate(draft, in: packageURL)
            let annotations = try loadUnlocked(from: packageURL)
            let annotation = RecordingAnnotation(
                id: UUID(),
                sequence: (annotations.map(\.sequence).max() ?? 0) + 1,
                createdAt: now,
                updatedAt: now,
                createdBy: author,
                updatedBy: author,
                kind: draft.kind,
                status: .open,
                text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
                startTimestampNs: draft.startTimestampNs,
                endTimestampNs: draft.endTimestampNs,
                applicationIDs: uniqueNonempty(draft.applicationIDs),
                accessibilityReferences: normalizedReferences(draft.accessibilityReferences),
                accessibilityNodeIDs: uniqueNonempty(draft.accessibilityNodeIDs),
                trace: draft.trace
            )
            try append(annotation, to: packageURL)
            return annotation
        }
    }

    public static func resolve(
        in packageURL: URL,
        reference: String,
        author: RecordingAnnotationAuthor,
        now: Date = Date()
    ) throws -> RecordingAnnotation {
        try lock.withLock {
            try validatePackage(packageURL)
            let annotations = try loadUnlocked(from: packageURL)
            guard let existing = annotations.first(where: {
                $0.reference.caseInsensitiveCompare(reference) == .orderedSame
            }) else {
                throw RecordingError.usage("Annotation \(reference) does not exist.")
            }
            let annotation = RecordingAnnotation(
                id: existing.id,
                sequence: existing.sequence,
                createdAt: existing.createdAt,
                updatedAt: now,
                createdBy: existing.createdBy,
                updatedBy: author,
                kind: existing.kind,
                status: .resolved,
                text: existing.text,
                startTimestampNs: existing.startTimestampNs,
                endTimestampNs: existing.endTimestampNs,
                applicationIDs: existing.applicationIDs,
                accessibilityReferences: existing.accessibilityReferences,
                accessibilityNodeIDs: existing.accessibilityNodeIDs,
                trace: existing.trace
            )
            try append(annotation, to: packageURL)
            return annotation
        }
    }

    private static func loadUnlocked(from packageURL: URL) throws -> [RecordingAnnotation] {
        try validatePackage(packageURL)
        let url = packageURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let annotations = try PabloProtobufCodec.decodeAnnotations(from: data)
        var latestByID: [UUID: RecordingAnnotation] = [:]
        for annotation in annotations { latestByID[annotation.id] = annotation }
        return latestByID.values.sorted { $0.sequence < $1.sequence }
    }

    private static func append(_ annotation: RecordingAnnotation, to packageURL: URL) throws {
        let url = packageURL.appendingPathComponent(filename)
        var data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        data.append(try PabloProtobufCodec.encode(annotation))
        try data.write(to: url, options: .atomic)
    }

    private static func validatePackage(_ packageURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(
                atPath: packageURL.appendingPathComponent("manifest.json").path
              ) else {
            throw RecordingError.usage("Not a Pablo recording package: \(packageURL.path)")
        }
        _ = try RecordingManifest.load(from: packageURL)
    }

    private static func validate(_ draft: RecordingAnnotationDraft, in packageURL: URL) throws {
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecordingError.usage("Annotation text cannot be empty.")
        }
        if let start = draft.startTimestampNs,
           let end = draft.endTimestampNs,
           end < start {
            throw RecordingError.usage("Annotation end time cannot precede its start time.")
        }
        if let trace = draft.trace {
            guard trace.isValid else {
                throw RecordingError.usage(
                    "A trace requires ordered samples with normalized x/y coordinates and a valid line width."
                )
            }
            if let start = draft.startTimestampNs,
               let traceStart = trace.startTimestampNs,
               traceStart < start {
                throw RecordingError.usage("The trace begins before the annotation start time.")
            }
            if let end = draft.endTimestampNs,
               let traceEnd = trace.endTimestampNs,
               traceEnd > end {
                throw RecordingError.usage("The trace ends after the annotation end time.")
            }
        }
        let manifest = try RecordingManifest.load(from: packageURL)
        let validApplicationIDs = Set(manifest.applications.map(\.id))
        let applicationIDs = uniqueNonempty(draft.applicationIDs)
        for applicationID in applicationIDs where !validApplicationIDs.contains(applicationID) {
            throw RecordingError.usage("Application \(applicationID) does not exist in this recording.")
        }
        let records = try accessibilityRecords(in: packageURL, manifest: manifest)
        let frameCount = records.count
        for reference in normalizedReferences(draft.accessibilityReferences) {
            guard let index = accessibilityIndex(reference), index < frameCount else {
                throw RecordingError.usage(
                    "Frame \(reference) does not exist; this recording has \(frameCount) accessibility frames."
                )
            }
            if !applicationIDs.isEmpty,
               !applicationIDs.contains(records[index].application.id) {
                throw RecordingError.usage(
                    "Frame \(reference) belongs to \(records[index].application.id), which is not an annotation application."
                )
            }
        }
        for nodeID in uniqueNonempty(draft.accessibilityNodeIDs) {
            guard let separator = nodeID.firstIndex(of: ":") else {
                throw RecordingError.usage("Accessibility node \(nodeID) has no application namespace.")
            }
            let applicationID = String(nodeID[..<separator])
            guard validApplicationIDs.contains(applicationID) else {
                throw RecordingError.usage("Accessibility node \(nodeID) names an unknown application.")
            }
            if !applicationIDs.isEmpty, !applicationIDs.contains(applicationID) {
                throw RecordingError.usage(
                    "Accessibility node \(nodeID) is not owned by an annotation application."
                )
            }
        }
    }

    private static func accessibilityRecords(
        in packageURL: URL,
        manifest: RecordingManifest
    ) throws -> [AXSnapshotRecord] {
        let url = try manifest.fileURL(for: "accessibility", in: packageURL)
        return try RecordingStreamReader.accessibility(at: url)
    }

    private static func normalizedReferences(_ references: [String]) -> [String] {
        var seen = Set<String>()
        return references.compactMap { reference in
            guard let index = accessibilityIndex(reference) else { return reference.uppercased() }
            let normalized = String(format: "A11Y-%03d", index + 1)
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    private static func accessibilityIndex(_ reference: String) -> Int? {
        var value = reference.uppercased()
        if value.hasPrefix("A11Y-") { value.removeFirst(5) }
        if value.hasPrefix("#") { value.removeFirst() }
        guard let number = Int(value), number > 0 else { return nil }
        return number - 1
    }

    private static func uniqueNonempty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}
