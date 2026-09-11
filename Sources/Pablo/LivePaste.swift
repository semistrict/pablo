import AppKit

public enum PabloLivePasteFormat: String, Codable, Sendable { case text, html }
public enum PabloLiveClipboardRestoration: String, Codable, Sendable {
    case restored, preservedNewerContent, failed
}

struct LiveClipboardItem: Equatable {
    let representations: [String: Data]
}

@MainActor
protocol LivePasteboard: AnyObject {
    var changeCount: Int { get }
    func readItems() throws -> [LiveClipboardItem]
    func replaceItems(_ items: [LiveClipboardItem]) throws
}

@MainActor
final class NativeLivePasteboard: LivePasteboard {
    private let pasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }

    func readItems() throws -> [LiveClipboardItem] {
        var bytes = 0
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= 128 else { throw RecordingError.usage("The clipboard contains too many items to preserve for a paste.") }
        return try items.map { item in
            var representations: [String: Data] = [:]
            guard item.types.count <= 128 else { throw RecordingError.usage("The clipboard contains too many representations to preserve for a paste.") }
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw RecordingError.capture("A clipboard representation could not be preserved; paste was not started.")
                }
                bytes += data.count
                guard bytes <= 32 * 1_024 * 1_024 else {
                    throw RecordingError.usage("The clipboard exceeds the 32 MiB preservation limit; paste was not started.")
                }
                representations[type.rawValue] = data
            }
            return .init(representations: representations)
        }
    }

    func replaceItems(_ items: [LiveClipboardItem]) throws {
        let native = items.map { value in
            let item = NSPasteboardItem()
            for (type, data) in value.representations { item.setData(data, forType: .init(type)) }
            return item
        }
        let clearedVersion = pasteboard.clearContents()
        if !native.isEmpty, !pasteboard.writeObjects(native) {
            throw LiveClipboardWriteFailure(ownedChangeCount: clearedVersion)
        }
    }
}

struct LivePasteFailure: LocalizedError {
    let underlying: Error
    let restoration: PabloLiveClipboardRestoration
    var errorDescription: String? {
        "Paste did not complete. Clipboard restoration: \(restoration.rawValue). Inspect the target before retrying."
    }
}

struct LiveClipboardWriteFailure: Error {
    let ownedChangeCount: Int
}

/// Owns temporary clipboard contents only until a newer writer changes the pasteboard.
@MainActor
enum LivePasteTransaction {
    static func perform(
        items: [LiveClipboardItem], pasteboard: any LivePasteboard,
        validate: () throws -> Void,
        paste: () async throws -> Void
    ) async throws -> PabloLiveClipboardRestoration {
        try Task.checkCancellation()
        let originalVersion = pasteboard.changeCount
        let original = try pasteboard.readItems()
        try validate()
        guard pasteboard.changeCount == originalVersion else {
            throw RecordingError.staleContext("The clipboard changed while being preserved; paste was not started.")
        }
        do { try pasteboard.replaceItems(items) } catch {
            // A failed write may have cleared the pasteboard; restore before reporting it.
            let restoration = restore(original, version: (error as? LiveClipboardWriteFailure)?.ownedChangeCount ?? originalVersion, pasteboard: pasteboard)
            throw LivePasteFailure(underlying: error, restoration: restoration)
        }
        let temporaryVersion = pasteboard.changeCount
        do {
            try Task.checkCancellation()
            try validate()
            try await paste()
            return restore(original, version: temporaryVersion, pasteboard: pasteboard)
        } catch {
            let restoration = restore(original, version: temporaryVersion, pasteboard: pasteboard)
            throw LivePasteFailure(underlying: error, restoration: restoration)
        }
    }

    private static func restore(_ items: [LiveClipboardItem], version: Int, pasteboard: any LivePasteboard) -> PabloLiveClipboardRestoration {
        guard pasteboard.changeCount == version else { return .preservedNewerContent }
        do { try pasteboard.replaceItems(items); return .restored } catch { return .failed }
    }

    static func items(text: String, format: PabloLivePasteFormat, plainText: String?) -> [LiveClipboardItem] {
        switch format {
        case .text: return [.init(representations: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)])]
        case .html:
            return [.init(representations: [NSPasteboard.PasteboardType.html.rawValue: Data(text.utf8),
                                            NSPasteboard.PasteboardType.string.rawValue: Data((plainText ?? "").utf8)])]
        }
    }
}
