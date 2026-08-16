import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let appGroupIdentifier = "D9G32AG3E5.com.ramon.pablo.safari"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        do {
            if let kind = message?["kind"] as? String, kind == "rrweb-events" {
                try storeRRWebEvents(message)
                complete(context, response: ["accepted": true])
                return
            }
            if let kind = message?["kind"] as? String, kind == "rrweb-error" {
                try storeRRWebError(message)
                complete(context, response: ["accepted": true])
                return
            }
            guard let requestID = message?["id"] as? String,
                  UUID(uuidString: requestID) != nil,
                  let encoded = message?["response"] as? String,
                  let data = Data(base64Encoded: encoded) else {
                throw BridgeError.invalidMessage
            }
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
            ) else {
                throw BridgeError.missingContainer
            }
            let responses = container
                .appendingPathComponent("Library/Application Support/Pablo/SafariBridge/Responses", isDirectory: true)
            try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
            try data.write(
                to: responses.appendingPathComponent("\(requestID).pb"),
                options: .atomic
            )
            complete(context, response: ["accepted": true])
        } catch {
            complete(context, response: ["accepted": false, "error": error.localizedDescription])
        }
    }

    private func storeRRWebEvents(_ message: [String: Any]?) throws {
        guard let recordingID = validRecordingID(message),
              let sequence = message?["sequence"] as? NSNumber,
              let events = message?["events"] as? [Any] else {
            throw BridgeError.invalidRRWebBatch
        }
        try spoolStore().storeEventBatch(
            recordingID: recordingID,
            sequence: sequence.int64Value,
            events: events
        )
    }

    private func storeRRWebError(_ message: [String: Any]?) throws {
        guard let recordingID = validRecordingID(message),
              let error = message?["error"] as? String else {
            throw BridgeError.invalidRRWebBatch
        }
        try spoolStore().storeError(recordingID: recordingID, message: error)
    }

    private func validRecordingID(_ message: [String: Any]?) -> UUID? {
        guard let value = message?["recordingID"] as? String else { return nil }
        return UUID(uuidString: value)
    }

    private func spoolStore() throws -> PabloRRWebSpoolStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw BridgeError.missingContainer
        }
        return PabloRRWebSpoolStore(rootDirectory: container.appendingPathComponent(
            "Library/Application Support/Pablo/RRWebSpool",
            isDirectory: true
        ))
    }

    private func complete(_ context: NSExtensionContext, response: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item])
    }
}

private enum BridgeError: LocalizedError {
    case invalidMessage
    case missingContainer
    case invalidRRWebBatch

    var errorDescription: String? {
        switch self {
        case .invalidMessage: "The Safari bridge received an invalid response."
        case .missingContainer: "The Safari bridge app-group container is unavailable."
        case .invalidRRWebBatch: "The Safari bridge received an invalid rrweb event batch."
        }
    }
}
