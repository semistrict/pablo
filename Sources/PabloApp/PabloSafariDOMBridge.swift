import AppKit
import Foundation
import PabloCore
import SafariServices

@MainActor
final class PabloSafariDOMBridge {
    static let extensionBundleIdentifier = "com.ramon.pablo.safari.extension"
    private static let appGroupIdentifier = "D9G32AG3E5.com.ramon.pablo.safari"
    private static let messageName = "dom-command"

    func listTabs() async throws -> [PabloSafariTab] {
        let output = try await perform(PabloSafariDOMRequest(kind: .listTabs))
        let data = try JSONEncoder().encode(output)
        return try JSONDecoder().decode(TabListPayload.self, from: data).tabs
    }

    func spoolDirectory(recordingID: UUID) throws -> URL {
        try spoolStore().recordingDirectory(recordingID: recordingID)
    }

    private func spoolStore() throws -> PabloRRWebSpoolStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw RecordingError.capture("Pablo's Safari app-group container is unavailable.")
        }
        return PabloRRWebSpoolStore(rootDirectory: container.appendingPathComponent(
            "Library/Application Support/Pablo/RRWebSpool",
            isDirectory: true
        ))
    }

    func prepareSpool(recordingID: UUID) throws {
        try spoolStore().prepare(recordingID: recordingID)
    }

    func removeSpool(recordingID: UUID) throws {
        try spoolStore().remove(recordingID: recordingID)
    }

    func eventBatches(recordingID: UUID) throws -> [Data] {
        try spoolStore().eventBatches(recordingID: recordingID)
    }

    func recordingError(recordingID: UUID) throws -> String? {
        try spoolStore().recordingError(recordingID: recordingID)
    }

    func perform(_ request: PabloSafariDOMRequest) async throws -> PabloControlOutput {
        try PabloSafariDOMProtocol.validate(request)
        guard safariIsRunning else {
            throw RecordingError.capture(
                "Safari is not running. Open it yourself first; Pablo will not bring Safari to the foreground."
            )
        }
        guard try await extensionIsEnabled() else {
            throw RecordingError.permission(
                "Enable Pablo Safari in Safari > Settings > Extensions, then click its toolbar button on the tab to unlock that tab."
            )
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw RecordingError.capture("Pablo's Safari app-group container is unavailable.")
        }

        let requestID = UUID()
        let responses = container
            .appendingPathComponent("Library/Application Support/Pablo/SafariBridge/Responses", isDirectory: true)
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        let responseURL = responses.appendingPathComponent("\(requestID.uuidString).pb")
        try? FileManager.default.removeItem(at: responseURL)
        defer { try? FileManager.default.removeItem(at: responseURL) }

        let command = try PabloSafariDOMProtocol.encode(request, id: requestID)
        try await SFSafariApplication.dispatchMessage(
            withName: Self.messageName,
            toExtensionWithIdentifier: Self.extensionBundleIdentifier,
            userInfo: [
                "name": Self.messageName,
                "command": command.base64EncodedString(),
            ]
        )

        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: responseURL) {
                let response = try PabloSafariDOMProtocol.decodeResponse(data)
                guard response.id == requestID else {
                    throw RecordingError.capture("The Safari extension returned a mismatched response.")
                }
                guard response.success else {
                    throw RecordingError.capture(
                        response.error ?? "The Safari extension rejected the DOM command."
                    )
                }
                guard let payload = response.jsonPayload else { return .null }
                return try JSONDecoder().decode(PabloControlOutput.self, from: payload)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RecordingError.capture(
            "The Safari extension did not respond. Click Pablo's Safari toolbar button on the active tab, then retry."
        )
    }

    private var safariIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            application.bundleIdentifier == "com.apple.Safari"
        }
    }

    private func extensionIsEnabled() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(
                withIdentifier: Self.extensionBundleIdentifier
            ) { state, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: state?.isEnabled == true)
                }
            }
        }
    }
}

private struct TabListPayload: Decodable {
    let kind: String
    let tabs: [PabloSafariTab]
}
