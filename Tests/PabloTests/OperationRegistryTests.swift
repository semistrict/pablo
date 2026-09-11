import Foundation
import Testing
@testable import PabloApp
@testable import PabloCore

@MainActor
private func operationResponse() -> PabloControlResponse {
    .init(id: UUID(), result: .init(state: "idle", scopeName: nil, applicationIDs: [],
        recordingPath: nil, elapsedNanoseconds: 0))
}

@Test("Operation receipts deduplicate and bind the verified caller, payload, and service")
@MainActor
func operationReceiptsBindContext() async throws {
    let registry = OperationRegistry(serviceID: UUID())
    let request = PabloOperationExecuteRequest(serviceID: registry.serviceID, method: .stopRecording)
    var effects = 0
    let result = try await registry.perform(request, caller: "signed:A") { effects += 1; return operationResponse() }
    let repeatResult = try await registry.perform(request, caller: "signed:A") { effects += 1; return operationResponse() }
    #expect(result.status == .completed)
    #expect(repeatResult.response?.id == result.response?.id)
    #expect(effects == 1)
    await #expect(throws: Error.self) {
        _ = try await registry.perform(request, caller: "signed:B") { effects += 1; return operationResponse() }
    }
    let changed = PabloOperationExecuteRequest(serviceID: registry.serviceID, operationID: request.operationID,
        issuedAt: request.issuedAt, method: .pauseRecording)
    await #expect(throws: Error.self) {
        _ = try await registry.perform(changed, caller: "signed:A") { effects += 1; return operationResponse() }
    }
    #expect(throws: Error.self) {
        try registry.lookup(.init(serviceID: UUID(), operationID: request.operationID), caller: "signed:A")
    }
    #expect(effects == 1)
}

@Test("Pending operations remain observable and cancellation prevents later dispatch")
@MainActor
func operationCancellationBeforeDispatch() async throws {
    let registry = OperationRegistry(serviceID: UUID())
    let request = PabloOperationExecuteRequest(serviceID: registry.serviceID, method: .stopRecording)
    let lookup = PabloOperationLookupRequest(serviceID: registry.serviceID, operationID: request.operationID)
    var entered = false
    var effects = 0
    let task = Task {
        try await registry.perform(request, caller: "signed:A") {
            entered = true
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return .init(id: UUID(), error: "Cancelled before dispatch",
                failure: .init(code: .cancelled, dispatchStatus: .notDispatched)) }
            effects += 1
            return operationResponse()
        }
    }
    while !entered { await Task.yield() }
    #expect(try registry.lookup(lookup, caller: "signed:A").status == .awaitingHuman)
    #expect(throws: Error.self) { try registry.cancel(lookup, caller: "signed:B") }
    #expect(try registry.cancel(lookup, caller: "signed:A").status == .cancellationRequested)
    let result = try await task.value
    #expect(result.status == .rejected)
    #expect(effects == 0)
}

@Test("Expired receipts and bounded admission cannot silently reexecute old requests")
@MainActor
func operationExpiryAndCapacity() async throws {
    var now = Date()
    let registry = OperationRegistry(serviceID: UUID(), capacity: 1, now: { now })
    let request = PabloOperationExecuteRequest(serviceID: registry.serviceID, issuedAt: now, method: .stopRecording)
    var effects = 0
    _ = try await registry.perform(request, caller: "signed:A") { effects += 1; return operationResponse() }
    await #expect(throws: Error.self) {
        _ = try await registry.perform(.init(serviceID: registry.serviceID, method: .stopRecording), caller: "signed:A") {
            effects += 1; return operationResponse()
        }
    }
    now = now.addingTimeInterval(301)
    await #expect(throws: Error.self) {
        _ = try await registry.perform(request, caller: "signed:A") { effects += 1; return operationResponse() }
    }
    #expect(effects == 1)
}

@Test("Operation wrappers validate nested payloads and cannot wrap themselves or reads")
func operationNestedValidation() {
    #expect(throws: Error.self) { try PabloOperationExecuteRequest(serviceID: UUID(), method: .executeOperation).validatedRequest() }
    #expect(throws: Error.self) { try PabloOperationExecuteRequest(serviceID: UUID(), method: .status).validatedRequest() }
    #expect(throws: Error.self) { try PabloOperationExecuteRequest(serviceID: UUID(), method: .actLive).validatedRequest() }
}

@Test("Large action observations reach the executing connection while receipt storage stays bounded")
@MainActor
func operationLargeResultsAreDeliveredOnce() async throws {
    let registry = OperationRegistry(serviceID: UUID())
    let request = PabloOperationExecuteRequest(serviceID: registry.serviceID, method: .stopRecording)
    let response = PabloControlResponse(id: UUID(), result: .init(state: "idle", scopeName: nil, applicationIDs: [],
        recordingPath: nil, elapsedNanoseconds: 0, output: .string(String(repeating: "x", count: 300 * 1_024))))
    let direct = try await registry.perform(request, caller: "fixture") { response }
    #expect(direct.response?.result?.output == response.result?.output)
    #expect(!direct.resultOmitted)
    let retained = try registry.lookup(.init(serviceID: registry.serviceID, operationID: request.operationID), caller: "fixture")
    #expect(retained.status == .completed)
    #expect(retained.resultOmitted)
    #expect(retained.response == nil)
    var repeats = 0
    let duplicate = try await registry.perform(request, caller: "fixture") { repeats += 1; return response }
    #expect(duplicate.resultOmitted)
    #expect(repeats == 0)
}
