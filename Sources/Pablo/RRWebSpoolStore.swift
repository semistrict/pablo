import Foundation

public struct PabloRRWebSpoolStore: Sendable {
    public static let maximumBatchBytes = 16 * 1_024 * 1_024
    public static let maximumSequence: Int64 = 1_000_000_000
    public static let maximumErrorBytes = 16_384

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func prepare(recordingID: UUID, fileManager: FileManager = .default) throws {
        let directory = recordingDirectory(recordingID: recordingID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func remove(recordingID: UUID, fileManager: FileManager = .default) throws {
        let directory = recordingDirectory(recordingID: recordingID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    public func storeEventBatch(
        recordingID: UUID,
        sequence: Int64,
        events: [Any],
        fileManager: FileManager = .default
    ) throws {
        guard (0...Self.maximumSequence).contains(sequence),
              JSONSerialization.isValidJSONObject(events) else {
            throw PabloRRWebSpoolError.invalidEventBatch
        }
        let data = try JSONSerialization.data(withJSONObject: events)
        guard data.count <= Self.maximumBatchBytes else {
            throw PabloRRWebSpoolError.oversizedEventBatch
        }
        let chunks = recordingDirectory(recordingID: recordingID)
            .appendingPathComponent("Chunks", isDirectory: true)
        // Only prepare owns the recording directory. Late delivery must never recreate a removed spool.
        guard fileManager.fileExists(atPath: chunks.deletingLastPathComponent().path) else {
            throw PabloRRWebSpoolError.inactiveRecording
        }
        if !fileManager.fileExists(atPath: chunks.path) {
            try fileManager.createDirectory(at: chunks, withIntermediateDirectories: false)
        }
        let filename = String(format: "%012lld.json", sequence)
        try data.write(to: chunks.appendingPathComponent(filename), options: .atomic)
    }

    public func storeError(
        recordingID: UUID,
        message: String,
        fileManager: FileManager = .default
    ) throws {
        let directory = recordingDirectory(recordingID: recordingID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw PabloRRWebSpoolError.inactiveRecording
        }
        var data = Data()
        for scalar in message.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            guard data.count + bytes.count <= Self.maximumErrorBytes else { break }
            data.append(bytes)
        }
        try data.write(
            to: directory.appendingPathComponent("error.txt"),
            options: .atomic
        )
    }

    public func eventBatches(
        recordingID: UUID,
        expectedNextSequence: Int64? = nil,
        expectedEventCount: Int? = nil,
        fileManager: FileManager = .default
    ) throws -> [Data] {
        let chunks = recordingDirectory(recordingID: recordingID)
            .appendingPathComponent("Chunks", isDirectory: true)
        let files = try fileManager.fileExists(atPath: chunks.path) ? fileManager.contentsOfDirectory(
            at: chunks,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) : []
        let ordered = files
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let expectedNextSequence {
            guard (0...Self.maximumSequence + 1).contains(expectedNextSequence),
                  ordered.count == expectedNextSequence,
                  ordered.enumerated().allSatisfy({ index, file in
                      file.lastPathComponent == String(format: "%012lld.json", Int64(index))
                  }) else {
                throw PabloRRWebSpoolError.incompleteDelivery
            }
        }
        let batches = try ordered.map { try Data(contentsOf: $0) }
        if let expectedEventCount {
            let count = try batches.reduce(0) { count, data in
                guard let events = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                    throw PabloRRWebSpoolError.invalidEventBatch
                }
                return count + events.count
            }
            guard count == expectedEventCount else { throw PabloRRWebSpoolError.incompleteDelivery }
        }
        return batches
    }

    public func recordingError(
        recordingID: UUID,
        fileManager: FileManager = .default
    ) throws -> String? {
        let url = recordingDirectory(recordingID: recordingID).appendingPathComponent("error.txt")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func recordingDirectory(recordingID: UUID) -> URL {
        rootDirectory.appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }
}

public enum PabloRRWebSpoolError: LocalizedError {
    case invalidEventBatch
    case oversizedEventBatch
    case inactiveRecording
    case incompleteDelivery

    public var errorDescription: String? {
        switch self {
        case .invalidEventBatch:
            "The Safari bridge received an invalid rrweb event batch."
        case .oversizedEventBatch:
            "The Safari bridge rejected an rrweb event batch larger than 16 MiB."
        case .inactiveRecording:
            "The Safari recording spool is no longer active."
        case .incompleteDelivery:
            "The Safari recording spool does not contain all acknowledged events and batches."
        }
    }
}
