import CryptoKit
import Foundation
import PabloCore

/// Keeps only a payload digest and bounded results; raw typed input lives in the running call.
@MainActor
final class OperationRegistry {
    private struct Entry {
        let caller: String
        let fingerprint: Data
        var receipt: PabloOperationReceipt
    }
    let serviceID: UUID
    private let capacity: Int
    private let now: () -> Date
    private var entries: [UUID: Entry] = [:]
    private var tasks: [UUID: Task<PabloControlResponse, Never>] = [:]
    var didChange: ((PabloOperationReceipt) -> Void)?

    init(serviceID: UUID, capacity: Int = 64, now: @escaping () -> Date = Date.init) {
        self.serviceID = serviceID
        self.capacity = max(1, min(capacity, 128))
        self.now = now
    }

    func lookup(_ request: PabloOperationLookupRequest, caller: String) throws -> PabloOperationReceipt {
        guard request.serviceID == serviceID, let entry = entries[request.operationID],
              entry.caller == caller, entry.receipt.expiresAt > now() || tasks[request.operationID] != nil else {
            throw RecordingError.usage("The receipt is unavailable, expired, or belongs to another service. This does not establish that the operation was not executed. Do not replay it.")
        }
        return entry.receipt
    }

    func cancel(_ request: PabloOperationLookupRequest, caller: String) throws -> PabloOperationReceipt {
        var receipt = try lookup(request, caller: caller)
        if tasks[request.operationID] != nil {
            tasks[request.operationID]?.cancel()
            receipt.status = .cancellationRequested
            update(receipt)
        }
        return receipt
    }

    func markRunning(_ operationID: UUID) {
        guard var receipt = entries[operationID]?.receipt, receipt.status == .awaitingHuman else { return }
        receipt.status = .running
        update(receipt)
    }

    func perform(_ request: PabloOperationExecuteRequest, caller: String,
                 execute: @escaping @MainActor () async -> PabloControlResponse) async throws -> PabloOperationReceipt {
        _ = try request.validatedRequest()
        let current = now()
        guard request.serviceID == serviceID, request.issuedAt > current.addingTimeInterval(-300),
              request.issuedAt <= current.addingTimeInterval(5) else {
            throw RecordingError.usage("The operation belongs to an expired service or request window. Read current state; do not replay the command.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprint = Data(SHA256.hash(data: try encoder.encode(request)))
        if let prior = entries[request.operationID] {
            guard prior.caller == caller, prior.fingerprint == fingerprint else {
                throw RecordingError.usage("This operation ID is already bound to another caller or payload.")
            }
            return prior.receipt
        }
        entries = entries.filter { $0.value.receipt.expiresAt > current || tasks[$0.key] != nil }
        guard entries.count < capacity else {
            throw RecordingError.capture("The operation receipt store is full. No operation was dispatched.")
        }
        var receipt = PabloOperationReceipt(serviceID: serviceID, operationID: request.operationID,
            method: request.method, expiresAt: request.issuedAt.addingTimeInterval(300))
        entries[request.operationID] = Entry(caller: caller, fingerprint: fingerprint, receipt: receipt)
        didChange?(receipt)
        let task = Task { await execute() }
        tasks[request.operationID] = task
        let response = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        tasks.removeValue(forKey: request.operationID)
        if response.result != nil { receipt.status = .completed }
        else if response.failure?.dispatchStatus == .notDispatched { receipt.status = .rejected }
        else if response.failure?.code == .interrupted { receipt.status = .interrupted }
        else { receipt.status = .outcomeUnknown }
        // 64 receipts at 256 KiB each bounds retained response content to 16 MiB.
        if let data = try? encoder.encode(response), data.count <= 256 * 1_024 {
            receipt.response = response
        } else { receipt.resultOmitted = true }
        update(receipt)
        return receipt
    }

    private func update(_ receipt: PabloOperationReceipt) {
        entries[receipt.operationID]?.receipt = receipt
        didChange?(receipt)
    }
}
