import CryptoKit
import Foundation

/// Pages through one live node's complete AXValue, which accessibility snapshots cap.
///
/// Offsets and lengths are UTF-16 code units, matching accessibility text ranges such as
/// `selectedTextRange`. Pages never split a surrogate pair.
public struct PabloLiveTextReadOptions: Codable, Equatable, Sendable {
    public static let defaultMaxLength = 100_000
    public static let maximumLength = 1_000_000

    public let nodeID: String
    public let offset: Int
    public let maxLength: Int
    /// The fingerprint returned with the previous page; a changed value fails instead of mixing versions.
    public let fingerprint: String?

    public init(nodeID: String, offset: Int = 0, maxLength: Int = Self.defaultMaxLength, fingerprint: String? = nil) {
        self.nodeID = nodeID
        self.offset = offset
        self.maxLength = maxLength
        self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case nodeID, offset, maxLength, fingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            nodeID: try container.decode(String.self, forKey: .nodeID),
            offset: try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
            maxLength: try container.decodeIfPresent(Int.self, forKey: .maxLength) ?? Self.defaultMaxLength,
            fingerprint: try container.decodeIfPresent(String.self, forKey: .fingerprint)
        )
    }

    public func validate() throws {
        guard !nodeID.isEmpty, nodeID.utf8.count <= 512 else {
            throw RecordingError.usage("A live text read requires a node ID of at most 512 bytes.")
        }
        guard offset >= 0 else {
            throw RecordingError.usage("The text offset must be zero or greater.")
        }
        guard (1...Self.maximumLength).contains(maxLength) else {
            throw RecordingError.usage("maxLength must be from 1 to \(Self.maximumLength) UTF-16 code units.")
        }
        if let fingerprint {
            guard fingerprint.utf8.count == 64, fingerprint.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
                throw RecordingError.usage("A text fingerprint must be the 64-character lowercase hex value from a previous page.")
            }
        }
    }
}

struct LiveTextPage: Encodable, Equatable {
    let sessionID: UUID
    let nodeID: String
    let offset: Int
    let length: Int
    let totalLength: Int
    /// The offset of the following page, or nil when this page ends the value.
    let nextOffset: Int?
    /// SHA-256 of the complete value's UTF-8 bytes.
    let fingerprint: String
    let text: String

    init(sessionID: UUID, value: String, options: PabloLiveTextReadOptions) throws {
        let fingerprint = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        if let expected = options.fingerprint, expected != fingerprint {
            throw RecordingError.staleContext(
                "The text of live node \(options.nodeID) changed since the previous page. Read it again from offset 0."
            )
        }
        let units = value.utf16
        let totalLength = units.count
        guard options.offset <= totalLength else {
            throw RecordingError.usage(
                "Text offset \(options.offset) exceeds the value length of \(totalLength) UTF-16 code units."
            )
        }
        let start = units.index(units.startIndex, offsetBy: options.offset)
        guard start == units.endIndex || !UTF16.isTrailSurrogate(units[start]) else {
            throw RecordingError.usage("Text offset \(options.offset) splits a character. Continue from a returned nextOffset.")
        }
        var end = units.index(start, offsetBy: options.maxLength, limitedBy: units.endIndex) ?? units.endIndex
        if end != units.endIndex, UTF16.isTrailSurrogate(units[end]) {
            end = units.index(before: end)
            // A one-unit page at a surrogate pair carries the whole pair so reading still advances.
            if end == start { end = units.index(start, offsetBy: 2) }
        }
        guard let text = String(units[start..<end]) else {
            throw RecordingError.capture("The live text value is not valid Unicode.")
        }
        let length = units.distance(from: start, to: end)
        self.sessionID = sessionID
        self.nodeID = options.nodeID
        self.offset = options.offset
        self.length = length
        self.totalLength = totalLength
        self.nextOffset = end == units.endIndex ? nil : options.offset + length
        self.fingerprint = fingerprint
        self.text = text
    }
}
