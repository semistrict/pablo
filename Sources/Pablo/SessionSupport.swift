import Foundation
import Darwin
import SwiftProtobuf

final class SessionClock {
    private let origin: UInt64
    private let numer: UInt64
    private let denom: UInt64
    private let lock = NSLock()
    private var pausedAt: UInt64?
    private var pausedTicks: UInt64 = 0

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        origin = mach_continuous_time()
        numer = UInt64(info.numer)
        denom = UInt64(info.denom)
    }

    func nowNanoseconds() -> UInt64 {
        let ticks = lock.withLock {
            (pausedAt ?? mach_continuous_time()) - origin - pausedTicks
        }
        return denom.dividingFullWidth(ticks.multipliedFullWidth(by: numer)).quotient
    }

    func pause() {
        lock.withLock {
            if pausedAt == nil { pausedAt = mach_continuous_time() }
        }
    }

    func resume() {
        lock.withLock {
            guard let pausedAt else { return }
            pausedTicks += mach_continuous_time() - pausedAt
            self.pausedAt = nil
        }
    }
}

enum ProtobufStream {
    static let maximumFrameBytes = 64 * 1_024 * 1_024

    static func frame<Message: SwiftProtobuf.Message>(_ message: Message) throws -> Data {
        let payload: Data = try message.serializedBytes()
        guard payload.count <= maximumFrameBytes else {
            throw RecordingError.capture("A protobuf stream record exceeds the 64 MiB limit.")
        }
        var result = encodeVarint(UInt64(payload.count))
        result.append(payload)
        return result
    }

    static func decode<Message: SwiftProtobuf.Message>(
        _ type: Message.Type,
        from data: Data
    ) throws -> [Message] {
        var offset = data.startIndex
        var messages: [Message] = []
        while offset < data.endIndex {
            let length = try decodeVarint(from: data, offset: &offset)
            guard length <= UInt64(maximumFrameBytes) else {
                throw RecordingError.capture("A protobuf stream record exceeds the 64 MiB limit.")
            }
            guard length <= UInt64(data.distance(from: offset, to: data.endIndex)) else {
                throw RecordingError.capture("A protobuf stream ends inside a record.")
            }
            let end = data.index(offset, offsetBy: Int(length))
            do {
                messages.append(try Message(serializedBytes: data[offset..<end]))
            } catch {
                throw RecordingError.capture("A protobuf stream record is invalid: \(error.localizedDescription)")
            }
            offset = end
        }
        return messages
    }

    static func count(in data: Data) throws -> Int {
        var offset = data.startIndex
        var count = 0
        while offset < data.endIndex {
            let length = try decodeVarint(from: data, offset: &offset)
            guard length <= UInt64(maximumFrameBytes) else {
                throw RecordingError.capture("A protobuf stream record exceeds the 64 MiB limit.")
            }
            guard length <= UInt64(data.distance(from: offset, to: data.endIndex)) else {
                throw RecordingError.capture("A protobuf stream ends inside a record.")
            }
            offset = data.index(offset, offsetBy: Int(length))
            count += 1
        }
        return count
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
        return bytes
    }

    private static func decodeVarint(from data: Data, offset: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.endIndex else {
                throw RecordingError.capture("A protobuf stream ends inside a length prefix.")
            }
            let byte = data[offset]
            offset = data.index(after: offset)
            if shift == 63, byte > 1 {
                throw RecordingError.capture("A protobuf stream has an invalid length prefix.")
            }
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw RecordingError.capture("A protobuf stream has an invalid length prefix.")
    }
}

final class ProtobufStreamWriter<Value> {
    private let handle: FileHandle
    private let encode: (Value) throws -> Data
    private let lock = NSLock()
    private(set) var count = 0

    init(url: URL, encode: @escaping (Value) throws -> Data) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.encode = encode
    }

    func append(_ value: Value) throws {
        let data = try encode(value)
        try lock.withLock {
            try handle.write(contentsOf: data)
            count += 1
        }
    }

    func close() throws {
        try lock.withLock {
            try handle.synchronize()
            try handle.close()
        }
    }
}

public enum RecordingError: LocalizedError {
    case usage(String)
    case targetNotFound(String)
    case permission(String)
    case capture(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let message), .targetNotFound(let message), .permission(let message),
             .capture(let message):
            return message
        }
    }
}

extension ISO8601DateFormatter {
    static let recordingFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
