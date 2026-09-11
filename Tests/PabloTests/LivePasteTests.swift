import AppKit
import Testing
@testable import PabloCore

@Test("Paste preserves multiple clipboard items and all their binary representations")
@MainActor
func livePastePreservesNativeClipboardRepresentations() async throws {
    let native = NSPasteboard(name: .init("pablo-paste-test-\(UUID())"))
    defer { native.releaseGlobally() }
    let board = NativeLivePasteboard(native)
    let original = [LiveClipboardItem(representations: ["public.utf8-plain-text": Data("Existing".utf8), "example.binary": Data([0, 255, 4])]),
                    .init(representations: ["public.png": Data([1, 2, 3, 4])])]
    try board.replaceItems(original)
    let temporary = LivePasteTransaction.items(text: "<b>First</b><br>Second", format: .html, plainText: "First\nSecond")
    let restoration = try await LivePasteTransaction.perform(items: temporary, pasteboard: board, validate: {}) {
        let current = try board.readItems()
        #expect(current == temporary)
    }
    #expect(restoration == .restored)
    #expect(try board.readItems() == original)
}

@Test("Paste cancellation and dispatch failure restore the original clipboard")
@MainActor
func livePasteRestoresAfterCancellationAndFailure() async throws {
    for error in [CancellationError() as Error, RecordingError.interrupted("Focus changed")] {
        let board = PasteboardFixture()
        let original = board.items
        do {
            _ = try await LivePasteTransaction.perform(items: pasteItems("Temporary"), pasteboard: board, validate: {}) { throw error }
            Issue.record("Failed paste must not report successful dispatch")
        } catch let failure as LivePasteFailure {
            #expect(failure.restoration == .restored)
        }
        #expect(board.items == original)
    }
}

@Test("A user's newer clipboard contents survive paste cleanup")
@MainActor
func livePasteKeepsNewerClipboardContents() async throws {
    let board = PasteboardFixture()
    let newer = pasteItems("Human copied this")
    let restoration = try await LivePasteTransaction.perform(items: pasteItems("Temporary"), pasteboard: board, validate: {}) {
        try board.replaceItems(newer)
    }
    #expect(restoration == .preservedNewerContent)
    #expect(board.items == newer)
    let failing = PasteboardFixture()
    failing.failWrite = 2
    #expect(try await LivePasteTransaction.perform(items: pasteItems("Temporary"), pasteboard: failing, validate: {}, paste: {}) == .failed)
}

@Test("Clipboard or target changes before dispatch prevent posting paste")
@MainActor
func livePasteRejectsChangedPreparation() async throws {
    let board = PasteboardFixture()
    let newer = pasteItems("Newer")
    var posts = 0
    do {
        _ = try await LivePasteTransaction.perform(items: pasteItems("Temporary"), pasteboard: board,
            validate: { try board.replaceItems(newer) }, paste: { posts += 1 })
        Issue.record("A clipboard change during preparation must stop paste")
    } catch is RecordingError {}
    #expect(posts == 0)
    #expect(board.items == newer)
    let stale = PasteboardFixture()
    var validations = 0
    do {
        _ = try await LivePasteTransaction.perform(items: pasteItems("Temporary"), pasteboard: stale, validate: {
            validations += 1
            if validations == 2 { throw RecordingError.staleContext("Fixture changed") }
        }, paste: { posts += 1 })
        Issue.record("The final target validation must prevent posting")
    } catch let failure as LivePasteFailure { #expect(failure.restoration == .restored) }
    #expect(posts == 0)
    #expect(stale.items == pasteItems("Original"))
}

private func pasteItems(_ text: String) -> [LiveClipboardItem] {
    [.init(representations: ["public.utf8-plain-text": Data(text.utf8)])]
}

@MainActor
private final class PasteboardFixture: LivePasteboard {
    var changeCount = 0
    var items = pasteItems("Original")
    var writes = 0
    var failWrite: Int?
    func readItems() throws -> [LiveClipboardItem] { items }
    func replaceItems(_ items: [LiveClipboardItem]) throws {
        writes += 1
        if writes == failWrite { throw RecordingError.capture("Fixture write failed") }
        self.items = items
        changeCount += 1
    }
}
