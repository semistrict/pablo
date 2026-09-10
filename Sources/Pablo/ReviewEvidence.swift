import Foundation

public enum PabloEvidenceAvailability: String, Codable, Sendable {
    case available, unavailable, unsupported
}

public struct PabloReviewObservation: Codable, Equatable, Sendable {
    public let reference: String
    public let applicationID: String
    public let timestampNs: UInt64
    public let ageNanoseconds: UInt64
    public let truncated: Bool
    public init(reference: String, applicationID: String, timestampNs: UInt64, ageNanoseconds: UInt64, truncated: Bool) {
        self.reference = reference; self.applicationID = applicationID; self.timestampNs = timestampNs
        self.ageNanoseconds = ageNanoseconds; self.truncated = truncated
    }
}

public enum PabloReviewEvidenceKind: String, Codable, Sendable { case point, timeline, image }

public struct PabloReviewEvidenceRequest: Codable, Sendable {
    public let reviewID: UUID
    public let serviceID: UUID
    public let expectedSourceGeneration: UUID
    public let expectedRevision: UInt64
    public var kind: PabloReviewEvidenceKind
    public var x: Double?
    public var y: Double?
    public var fromSeconds: Double?
    public var toSeconds: Double?
    public var after: Int
    public var limit: Int
    public var maxPixelDimension: Int

    public init(reviewID: UUID, serviceID: UUID, expectedSourceGeneration: UUID, expectedRevision: UInt64,
                kind: PabloReviewEvidenceKind, x: Double? = nil, y: Double? = nil,
                fromSeconds: Double? = nil, toSeconds: Double? = nil, after: Int = 0, limit: Int = 100,
                maxPixelDimension: Int = 1_600) {
        self.reviewID = reviewID; self.serviceID = serviceID; self.expectedSourceGeneration = expectedSourceGeneration
        self.expectedRevision = expectedRevision; self.kind = kind; self.x = x; self.y = y
        self.fromSeconds = fromSeconds; self.toSeconds = toSeconds; self.after = after; self.limit = limit
        self.maxPixelDimension = maxPixelDimension
    }

    private enum CodingKeys: String, CodingKey {
        case reviewID, serviceID, expectedSourceGeneration, expectedRevision, kind, x, y
        case fromSeconds, toSeconds, after, limit, maxPixelDimension
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(reviewID: try values.decode(UUID.self, forKey: .reviewID),
                  serviceID: try values.decode(UUID.self, forKey: .serviceID),
                  expectedSourceGeneration: try values.decode(UUID.self, forKey: .expectedSourceGeneration),
                  expectedRevision: try values.decode(UInt64.self, forKey: .expectedRevision),
                  kind: try values.decode(PabloReviewEvidenceKind.self, forKey: .kind),
                  x: try values.decodeIfPresent(Double.self, forKey: .x), y: try values.decodeIfPresent(Double.self, forKey: .y),
                  fromSeconds: try values.decodeIfPresent(Double.self, forKey: .fromSeconds),
                  toSeconds: try values.decodeIfPresent(Double.self, forKey: .toSeconds),
                  after: try values.decodeIfPresent(Int.self, forKey: .after) ?? 0,
                  limit: try values.decodeIfPresent(Int.self, forKey: .limit) ?? 100,
                  maxPixelDimension: try values.decodeIfPresent(Int.self, forKey: .maxPixelDimension) ?? 1_600)
    }

    public func validate() throws {
        guard after >= 0, (1...200).contains(limit), (64...2_048).contains(maxPixelDimension),
              [fromSeconds, toSeconds].allSatisfy({ $0.map { $0.isFinite && $0 >= 0 && $0 <= 9_223_372_036 } ?? true }),
              fromSeconds == nil || toSeconds == nil || fromSeconds! <= toSeconds! else {
            throw RecordingError.usage("Invalid review evidence range or output bound.")
        }
        if kind == .point {
            guard let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw RecordingError.usage("Recorded point coordinates must be inside the normalized review viewport.")
            }
        }
    }
}

public struct PabloReviewImage: Codable, Sendable {
    public let mimeType: String
    public let base64: String
    public let width: Int
    public let height: Int
    public let renderedSeconds: Double
    public init(base64: String, width: Int, height: Int, renderedSeconds: Double) {
        self.mimeType = "image/png"
        self.base64 = base64; self.width = width; self.height = height; self.renderedSeconds = renderedSeconds
    }
}

public struct PabloReviewEvidence: Codable, Sendable {
    public var state: PabloReviewState
    public var node: ReplayAccessibilityNode?
    public var observation: PabloReviewObservation?
    /// The node bounds, normalized within state.viewport.
    public var region: RecordingRect?
    public var items: [ReplayTimelineItem] = []
    public var nextCursor = 0
    public var hasMore = false
    public var image: PabloReviewImage?
    public init(state: PabloReviewState) { self.state = state }
}
