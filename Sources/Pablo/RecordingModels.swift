import Foundation

struct RecordingManifest: Codable {
    struct Target: Codable {
        let pid: Int32
        let bundleIdentifier: String?
        let name: String
    }

    struct Capture: Codable {
        let displayScale: Double
        let width: Int
        let height: Int
        let framesPerSecond: Int
        var firstFrameTimestampNs: UInt64?
    }

    let schemaVersion: Int
    let startedAt: String
    var endedAt: String?
    var durationNs: UInt64?
    let target: Target
    var capture: Capture
    let files: [String: String]
}

struct InputEventRecord: Codable {
    let schemaVersion: Int
    let timestampNs: UInt64
    let type: String
    let targetPID: Int64?
    let x: Double?
    let y: Double?
    let deltaX: Double?
    let deltaY: Double?
    let keyCode: Int64?
    let text: String?
    let flags: UInt64
    let button: Int64?
    let clickCount: Int64?
}

struct AXNode: Codable, Equatable {
    let id: String
    let parentID: String?
    let childIDs: [String]
    let role: String?
    let subrole: String?
    let title: String?
    let label: String?
    let value: String?
    let identifier: String?
    let help: String?
    let enabled: Bool?
    let focused: Bool?
    let position: Point?
    let size: Size?

    struct Point: Codable, Equatable {
        let x: Double
        let y: Double
    }

    struct Size: Codable, Equatable {
        let width: Double
        let height: Double
    }
}

struct AXSnapshotRecord: Codable {
    let schemaVersion: Int
    let timestampNs: UInt64
    let reason: String
    let kind: String
    let rootID: String?
    let upserts: [AXNode]
    let removed: [String]
    let truncated: Bool
}

struct SessionSummary: Codable {
    let manifest: RecordingManifest
    let inputEventCount: Int
    let accessibilityRecordCount: Int
}
