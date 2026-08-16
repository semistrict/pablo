import Foundation
import Testing
@testable import PabloCore

private func temporarySpoolStore() throws -> (PabloRRWebSpoolStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-rrweb-spool-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return (PabloRRWebSpoolStore(rootDirectory: directory), directory)
}

@Test("rrweb spool batches are ordered and sequence writes are idempotent")
func rrwebSpoolOrdersBatches() throws {
    let (store, directory) = try temporarySpoolStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recordingID = UUID()
    try store.prepare(recordingID: recordingID)
    try store.storeEventBatch(
        recordingID: recordingID,
        sequence: 10,
        events: [["timestamp": 30]]
    )
    try store.storeEventBatch(
        recordingID: recordingID,
        sequence: 2,
        events: [["timestamp": 20]]
    )
    try store.storeEventBatch(
        recordingID: recordingID,
        sequence: 2,
        events: [["timestamp": 21]]
    )

    let batches = try store.eventBatches(recordingID: recordingID)
    let timestamps = try batches.map { data in
        let events = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Int]])
        return try #require(events.first?["timestamp"])
    }
    #expect(timestamps == [21, 30])
}

@Test("rrweb spool rejects invalid sequence and oversized event batches")
func rrwebSpoolRejectsInvalidBatches() throws {
    let (store, directory) = try temporarySpoolStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recordingID = UUID()

    #expect(throws: PabloRRWebSpoolError.self) {
        try store.storeEventBatch(recordingID: recordingID, sequence: -1, events: [])
    }
    #expect(throws: PabloRRWebSpoolError.self) {
        try store.storeEventBatch(
            recordingID: recordingID,
            sequence: 0,
            events: [["value": String(repeating: "x", count: PabloRRWebSpoolStore.maximumBatchBytes)]]
        )
    }
    #expect(try store.eventBatches(recordingID: recordingID).isEmpty)
}

@Test("rrweb spool bounds errors without producing invalid UTF-8")
func rrwebSpoolBoundsErrors() throws {
    let (store, directory) = try temporarySpoolStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recordingID = UUID()
    try store.storeError(
        recordingID: recordingID,
        message: String(repeating: "🙂", count: PabloRRWebSpoolStore.maximumErrorBytes)
    )

    let error = try store.recordingError(recordingID: recordingID)
    let stored = try #require(error)
    #expect(Data(stored.utf8).count <= PabloRRWebSpoolStore.maximumErrorBytes)
    #expect(!stored.isEmpty)
}

@Test("preparing and removing an rrweb spool clears prior chunks")
func rrwebSpoolLifecycle() throws {
    let (store, directory) = try temporarySpoolStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recordingID = UUID()
    try store.storeEventBatch(recordingID: recordingID, sequence: 0, events: [["type": 1]])
    #expect(try store.eventBatches(recordingID: recordingID).count == 1)

    try store.prepare(recordingID: recordingID)
    #expect(try store.eventBatches(recordingID: recordingID).isEmpty)
    try store.remove(recordingID: recordingID)
    #expect(!FileManager.default.fileExists(
        atPath: store.recordingDirectory(recordingID: recordingID).path
    ))
}
