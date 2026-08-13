import Foundation

enum RecordingStreamReader {
    static func events(at url: URL) throws -> [InputEventRecord] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try PabloProtobufCodec.decodeEvents(from: data)
    }

    static func accessibility(at url: URL) throws -> [AXSnapshotRecord] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try PabloProtobufCodec.decodeAccessibility(from: data)
    }

    static func workspace(at url: URL) throws -> [WorkspaceSnapshotRecord] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try PabloProtobufCodec.decodeWorkspace(from: data)
    }
}
