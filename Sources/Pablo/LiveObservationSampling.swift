import Foundation

public enum PabloLiveSettleStatus: String, Codable, Sendable {
    case sampled, settled, timedOut
}

public struct PabloLiveObservation: Codable, Sendable {
    public struct Target: Codable, Sendable {
        public let pid: Int32
        public let bundleIdentifier: String?
        public let applicationName: String
        public let windowID: String?
    }
    public let id: UUID
    public let target: Target
    public let tree: PabloLiveTreeObservation
    public let settleStatus: PabloLiveSettleStatus
    public let sampleCount: Int
    public let elapsedMilliseconds: Int
    public let screenshot: PabloLiveScreenshot?
}

/// Polling is bounded; a quiet AX tree is evidence of sampled stability, not an action's success.
@MainActor
enum LiveObservationSampler {
    struct Result {
        let tree: AXTreeSnapshot
        let status: PabloLiveSettleStatus
        let sampleCount: Int
        let elapsedMilliseconds: Int
    }

    static func sample(
        options: PabloLiveObservationOptions,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
        pause: (Int) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) },
        read: () throws -> AXTreeSnapshot
    ) async throws -> Result {
        try options.validate()
        try Task.checkCancellation()
        let start = now()
        var tree = try read()
        var samples = 1
        var unchangedSince = now()
        func result(_ status: PabloLiveSettleStatus) -> Result {
            .init(tree: tree, status: status, sampleCount: samples, elapsedMilliseconds: Int(now() - start))
        }
        if options.quietMilliseconds == 0 { return result(.sampled) }
        while true {
            try Task.checkCancellation()
            let elapsed = Int(now() - start)
            if elapsed >= options.timeoutMilliseconds { return result(.timedOut) }
            try await pause(min(50, options.timeoutMilliseconds - elapsed))
            try Task.checkCancellation()
            let next = try read()
            samples += 1
            if next.rootID != tree.rootID || next.nodes != tree.nodes || next.truncated != tree.truncated {
                unchangedSince = now()
            }
            tree = next
            if Int(now() - start) > options.timeoutMilliseconds { return result(.timedOut) }
            if Int(now() - unchangedSince) >= options.quietMilliseconds { return result(.settled) }
        }
    }
}
