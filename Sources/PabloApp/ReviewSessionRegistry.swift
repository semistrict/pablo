import Foundation
import PabloCore

/// The registry and each view use the same model; reading never activates a window.
@MainActor
final class ReviewSessionRegistry {
    static let shared = ReviewSessionRegistry()
    let serviceID = UUID()
    private var models: [UUID: ReplayModel] = [:]
    private var recency: [UUID] = []
    private(set) var activeReviewID: UUID?
    var activateWindow: ((UUID) async throws -> Void)?
    var closeWindow: ((UUID) -> Void)?
    private struct Receipt {
        let caller: String
        let request: PabloReviewCommandRequest
        var operation: PabloReviewOperation
    }
    private var receipts: [UUID: Receipt] = [:]
    private var runningTasks: [UUID: Task<Void, Error>] = [:]
    private var events: [PabloReviewChange] = []
    private var nextSequence: UInt64 = 0
    private let eventCapacity: Int
    private var pendingChanges: [UUID: (String, PabloChangeOrigin, UUID?)] = [:]
    private var flushScheduled = false

    init(eventCapacity: Int = 256) { self.eventCapacity = min(max(eventCapacity, 1), 10_000) }

    func publish(kind: String, reviewID: UUID? = nil, origin: PabloChangeOrigin,
                 operationID: UUID? = nil, detail: String? = nil) {
        nextSequence += 1
        var event = PabloReviewChange(sequence: nextSequence, kind: kind, origin: origin)
        event.reviewID = reviewID
        event.operationID = operationID
        event.detail = detail.map { String($0.prefix(1_024)) }
        if let reviewID, let model = models[reviewID] {
            event.sourceID = model.reviewSource?.sourceID
            event.sourceGeneration = model.reviewSource?.generation
            event.revision = model.contextRevision
        }
        events.append(event)
        if events.count > eventCapacity { events.removeFirst(events.count - eventCapacity) }
    }

    private func scheduleChange(_ id: UUID, kind: String, origin: PabloChangeOrigin, operationID: UUID?) {
        if let prior = pendingChanges[id], prior.1 != origin || prior.2 != operationID {
            // Mixed changes cannot be treated as an echo of one operation.
            let combined: PabloChangeOrigin = prior.1 == .human || origin == .human ? .human : .mixed
            pendingChanges[id] = ("reviewChanged", combined, nil)
        } else {
            pendingChanges[id] = (kind, origin, operationID)
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.flushPendingChanges()
        }
    }

    private func flushPendingChanges() {
        let pending = pendingChanges
        pendingChanges.removeAll()
        flushScheduled = false
        for (id, value) in pending.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where models[id] != nil {
            publish(kind: value.0, reviewID: id, origin: value.1, operationID: value.2)
        }
    }

    func watch(_ request: PabloChangeWatchRequest) async throws -> PabloChangePage {
        try request.validate()
        flushPendingChanges()
        if let requestedService = request.serviceID, requestedService != serviceID {
            return .init(serviceID: serviceID, events: [], nextCursor: nextSequence,
                         oldestSequence: events.first?.sequence ?? nextSequence + 1,
                         newestSequence: nextSequence, resyncRequired: true)
        }
        guard request.after <= nextSequence else { throw RecordingError.usage("The change cursor is ahead of this service.") }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(request.waitMs))
        while request.after == nextSequence, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            flushPendingChanges()
        }
        try Task.checkCancellation()
        let oldest = events.first?.sequence ?? nextSequence + 1
        let page = Array(events.lazy.filter { $0.sequence > request.after }.prefix(request.limit))
        return .init(serviceID: serviceID, events: page, nextCursor: page.last?.sequence ?? request.after,
                     oldestSequence: oldest, newestSequence: nextSequence, resyncRequired: request.after < oldest - 1)
    }

    func register(_ model: ReplayModel) {
        models[model.reviewID] = model
        if !recency.contains(model.reviewID) { recency.append(model.reviewID) }
        let id = model.reviewID
        model.reviewDidChange = { [weak self] kind, origin, operationID in
            self?.scheduleChange(id, kind: kind, origin: origin, operationID: operationID)
        }
        publish(kind: "reviewOpened", reviewID: id, origin: .system)
    }

    func activate(_ id: UUID) {
        guard models[id] != nil, activeReviewID != id else { return }
        activeReviewID = id
        publish(kind: "reviewActivated", reviewID: id, origin: .system)
        recency.removeAll { $0 == id }
        recency.insert(id, at: 0)
    }

    func remove(_ id: UUID) {
        publish(kind: "reviewClosed", reviewID: id, origin: .system)
        models[id]?.reviewDidChange = nil
        pendingChanges.removeValue(forKey: id)
        models[id]?.closeReview()
        models.removeValue(forKey: id)
        recency.removeAll { $0 == id }
        if activeReviewID == id { activeReviewID = nil }
    }

    func model(_ id: UUID) throws -> ReplayModel {
        guard let model = models[id] else {
            throw RecordingError.usage("The review is closed or unknown. Read review.list for open reviews.")
        }
        return model
    }

    func state(_ id: UUID) throws -> PabloReviewState {
        var snapshot = try model(id).reviewState()
        snapshot.serviceID = serviceID
        snapshot.isActive = activeReviewID == id
        return snapshot
    }

    func evidence(_ request: PabloReviewEvidenceRequest) async throws -> PabloReviewEvidence {
        try request.validate()
        let model = try model(request.reviewID)
        func verify() throws {
            guard request.serviceID == serviceID,
                  model.reviewSource?.generation == request.expectedSourceGeneration,
                  model.contextRevision == request.expectedRevision, model.sourceIsUnchanged() else {
                throw RecordingError.usage("The review evidence context changed. Read the current state before querying again.")
            }
        }
        try verify()
        var result = try await model.queryEvidence(request)
        try verify()
        result.state.serviceID = serviceID
        result.state.isActive = activeReviewID == request.reviewID
        return result
    }

    func states() -> [PabloReviewState] {
        recency.compactMap { try? state($0) }
    }

    func deactivate(_ id: UUID) {
        if activeReviewID == id {
            activeReviewID = nil
            publish(kind: "reviewDeactivated", reviewID: id, origin: .system)
        }
    }

    func operation(_ request: PabloReviewOperationRequest, caller: String) throws -> PabloReviewOperation {
        guard request.serviceID == serviceID, let receipt = receipts[request.operationID],
              receipt.caller == caller, receipt.operation.expiresAt > Date() else {
            throw RecordingError.usage("The operation receipt is unavailable or expired. This does not establish that the operation was not executed.")
        }
        return receipt.operation
    }

    /// Cancellation stops waiting and further dispatch; it cannot undo an issued seek or saved note.
    func cancel(_ request: PabloReviewOperationRequest, caller: String) throws -> PabloReviewOperation {
        var result = try operation(request, caller: caller)
        guard result.status == .running || result.status == .cancellationRequested else { return result }
        runningTasks[request.operationID]?.cancel()
        result.status = .cancellationRequested
        receipts[request.operationID]?.operation = result
        publish(kind: "operationChanged", reviewID: result.reviewID, origin: .application,
                operationID: result.operationID, detail: result.status.rawValue)
        return result
    }

    func perform(_ request: PabloReviewCommandRequest, caller: String, author: RecordingAnnotationAuthor? = nil) async throws -> PabloReviewOperation {
        try request.command.validate()
        let now = Date()
        guard request.serviceID == serviceID,
              request.issuedAt > now.addingTimeInterval(-300), request.issuedAt <= now.addingTimeInterval(5) else {
            throw RecordingError.usage("The operation belongs to an expired service or request window. Read the current state; do not replay the old command.")
        }
        if let prior = receipts[request.operationID] {
            guard prior.caller == caller, prior.request == request else {
                throw RecordingError.usage("The operation ID is already bound to another caller or command.")
            }
            return prior.operation
        }
        receipts = receipts.filter { $0.value.operation.expiresAt > now || runningTasks[$0.key] != nil }
        guard receipts.count < 128 else {
            throw RecordingError.capture("The operation receipt store is full. No command was executed.")
        }
        let model = try model(request.reviewID)
        var result = PabloReviewOperation(operationID: request.operationID, reviewID: request.reviewID,
                                          status: .running, expiresAt: request.issuedAt.addingTimeInterval(300))
        let before = try state(request.reviewID)
        if before.source?.generation != request.expectedSourceGeneration || before.revision != request.expectedRevision ||
            !model.sourceIsUnchanged() {
            result.status = .staleContext
            result.error = "The source or review context changed. Read the current state before choosing another command."
        } else if before.draft != nil && ![PabloReviewCommandKind.pause, .showInspector].contains(request.command.kind) {
            result.status = .draftConflict
            result.error = "This review has an unsaved human draft. The command did not change it."
        }
        result.state = before
        receipts[request.operationID] = Receipt(caller: caller, request: request, operation: result)
        publish(kind: "operationChanged", reviewID: request.reviewID, origin: .application,
                operationID: request.operationID, detail: result.status.rawValue)
        guard result.status == .running else { return result }
        do {
            try Task.checkCancellation()
            switch request.command.kind {
            case .annotate:
                guard let author else { throw RecordingError.usage("Annotation creation requires the app-verified caller provenance.") }
                result.annotation = try model.addApprovedAnnotation(request.command, author: author, operationID: request.operationID)
                result.annotationReference = result.annotation?.reference
            case .activate:
                guard let activateWindow else { throw RecordingError.capture("The review window is unavailable.") }
                try await run(operationID: request.operationID) {
                    try await activateWindow(request.reviewID)
                }
                guard model.sourceIsUnchanged(), model.contextRevision == before.revision else {
                    throw CancellationError()
                }
            case .close:
                guard let closeWindow else { throw RecordingError.capture("The review window is unavailable.") }
                closeWindow(request.reviewID)
            default:
                try await run(operationID: request.operationID) {
                    try await model.performReviewCommand(request.command, operationID: request.operationID)
                }
                guard model.sourceIsUnchanged() else { throw CancellationError() }
            }
            result.status = .completed
        } catch is CancellationError {
            result.status = .interrupted
            result.error = "The review operation was interrupted. Read its current state before continuing."
        } catch {
            result.status = .failed
            result.error = error.localizedDescription
        }
        result.state = try? state(request.reviewID)
        receipts[request.operationID]?.operation = result
        publish(kind: "operationChanged", reviewID: request.reviewID, origin: .application,
                operationID: request.operationID, detail: result.status.rawValue)
        return result
    }

    private func run(operationID: UUID, _ operation: @escaping @MainActor () async throws -> Void) async throws {
        let task = Task { try await operation() }
        runningTasks[operationID] = task
        defer { runningTasks.removeValue(forKey: operationID) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
    }

}
