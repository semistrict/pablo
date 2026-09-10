import Foundation

public struct PabloLiveIndexedEvent: Codable, Sendable {
    public let sequence: UInt64
    public let record: InputEventRecord
}

public struct PabloLiveEventPage: Codable, Sendable {
    public var sessionID: UUID?
    public var observing = false
    public var capturesText = false
    public let events: [PabloLiveIndexedEvent]
    public let nextCursor: UInt64
    public let oldestSequence: UInt64
    public let newestSequence: UInt64
    public let resyncRequired: Bool
}

/// The observer owns synchronization; this value contains only bounded cursor semantics.
struct LiveEventHistory {
    private(set) var events: [PabloLiveIndexedEvent] = []
    private var nextSequence: UInt64 = 1
    private let maximumEvents: Int

    init(maximumEvents: Int = 10_000) { self.maximumEvents = min(max(maximumEvents, 1), 10_000) }

    mutating func append(_ record: InputEventRecord) {
        events.append(.init(sequence: nextSequence, record: record))
        nextSequence += 1
        if events.count > maximumEvents { events.removeFirst(events.count - maximumEvents) }
    }

    func validatePage(after: UInt64?, limit: Int) throws {
        guard (1...10_000).contains(limit), after.map({ $0 < nextSequence }) ?? true else {
            throw RecordingError.usage("The live event cursor or page limit is invalid.")
        }
    }

    func page(after: UInt64?, limit: Int) throws -> PabloLiveEventPage {
        try validatePage(after: after, limit: limit)
        let oldest = events.first?.sequence ?? nextSequence
        let selected = after.map { cursor in Array(events.lazy.filter { $0.sequence > cursor }.prefix(limit)) }
            ?? Array(events.suffix(limit))
        return .init(events: selected, nextCursor: selected.last?.sequence ?? after ?? nextSequence - 1,
                     oldestSequence: oldest, newestSequence: nextSequence - 1,
                     resyncRequired: after.map { $0 < oldest - 1 } ?? false)
    }
}

public struct PabloLiveObservationState: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let pid: Int32
    public let applicationName: String
    public let bundleIdentifier: String?
    public let capturesText: Bool
    public init(id: UUID, pid: Int32, applicationName: String, bundleIdentifier: String?, capturesText: Bool) {
        self.id = id; self.pid = pid; self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier; self.capturesText = capturesText
    }
}
