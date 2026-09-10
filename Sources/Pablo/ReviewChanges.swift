import Foundation

public enum PabloChangeOrigin: String, Codable, Sendable {
    case human, application, renderer, system, mixed
}

public struct PabloChangeWatchRequest: Codable, Sendable {
    public var serviceID: UUID?
    public var after: UInt64
    public var limit: Int
    public var waitMs: Int
    public init(serviceID: UUID? = nil, after: UInt64 = 0, limit: Int = 100, waitMs: Int = 0) {
        self.serviceID = serviceID; self.after = after; self.limit = limit; self.waitMs = waitMs
    }
    public func validate() throws {
        guard (1...100).contains(limit), (0...25_000).contains(waitMs) else {
            throw RecordingError.usage("Change watch limit must be 1...100 and waitMs must be 0...25000.")
        }
    }
    private enum CodingKeys: String, CodingKey { case serviceID, after, limit, waitMs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(serviceID: try values.decodeIfPresent(UUID.self, forKey: .serviceID),
                  after: try values.decodeIfPresent(UInt64.self, forKey: .after) ?? 0,
                  limit: try values.decodeIfPresent(Int.self, forKey: .limit) ?? 100,
                  waitMs: try values.decodeIfPresent(Int.self, forKey: .waitMs) ?? 0)
    }
}

public struct PabloReviewChange: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let kind: String
    public let origin: PabloChangeOrigin
    public var reviewID: UUID?
    public var sourceID: String?
    public var sourceGeneration: UUID?
    public var revision: UInt64?
    public var operationID: UUID?
    public var detail: String?
    public init(sequence: UInt64, kind: String, origin: PabloChangeOrigin) {
        self.sequence = sequence; self.kind = kind; self.origin = origin
    }
}

public struct PabloChangePage: Codable, Equatable, Sendable {
    public let serviceID: UUID
    public let events: [PabloReviewChange]
    public let nextCursor: UInt64
    public let oldestSequence: UInt64
    public let newestSequence: UInt64
    public let resyncRequired: Bool
    public init(serviceID: UUID, events: [PabloReviewChange], nextCursor: UInt64,
                oldestSequence: UInt64, newestSequence: UInt64, resyncRequired: Bool) {
        self.serviceID = serviceID; self.events = events; self.nextCursor = nextCursor
        self.oldestSequence = oldestSequence; self.newestSequence = newestSequence
        self.resyncRequired = resyncRequired
    }
}
