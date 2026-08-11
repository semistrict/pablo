import Foundation
import Darwin

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

final class JSONLWriter<Value: Encodable> {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let lock = NSLock()
    private(set) var count = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func append(_ value: Value) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
        count += 1
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.synchronize()
        try handle.close()
    }
}

enum RecordingError: LocalizedError {
    case usage(String)
    case targetNotFound(String)
    case permission(String)
    case capture(String)

    var errorDescription: String? {
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
