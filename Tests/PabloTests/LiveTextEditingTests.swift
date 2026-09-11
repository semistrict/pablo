import Foundation
import Testing
@testable import PabloCore

@Test("Precise selections use UTF-16 ranges and disambiguate adjacent context")
func liveTextSelectionUsesUnicodeAndContext() throws {
    let content = "🙂 first café; second café!"
    #expect(throws: RecordingError.self) { try LiveTextSelectionRange.resolve(text: "café", in: content, options: .init()) }
    let range = try LiveTextSelectionRange.resolve(text: "café", in: content, options: .init(prefix: "second ", suffix: "!"))
    #expect((content as NSString).substring(with: range) == "café")
    #expect(range.location == ("🙂 first café; second " as NSString).length)
    #expect(try LiveTextSelectionRange.resolve(text: "café", in: content,
        options: .init(prefix: "second ", selectionType: .cursorBefore)) == NSRange(location: range.location, length: 0))
    #expect(try LiveTextSelectionRange.resolve(text: "café", in: content,
        options: .init(prefix: "second ", selectionType: .cursorAfter)) == NSRange(location: NSMaxRange(range), length: 0))
    #expect(throws: RecordingError.self) { try LiveTextSelectionRange.resolve(text: "aa", in: "aaa", options: .init()) }
    #expect(throws: RecordingError.self) { try LiveTextSelectionRange.resolve(text: "café", in: content, options: .init(suffix: "?")) }
    #expect(try LiveTextSelectionRange.resolve(text: "e\u{301}", in: "🙂e\u{301}", options: .init()) == NSRange(location: 2, length: 2))
}

@Test("Text selection rejects a field edited during resolution before setting a range")
@MainActor
func liveTextSelectionRejectsChangedValues() throws {
    let target = TextEditingFixture(values: ["Before phrase", "Changed phrase"])
    #expect(throws: RecordingError.self) { try LiveTextEditor.select("phrase", options: .init(), target: target) }
    #expect(target.selections.isEmpty)
    #expect(target.replacements.isEmpty)
    let stable = TextEditingFixture(values: ["🙂 phrase"])
    try LiveTextEditor.select("phrase", options: .init(), target: stable)
    #expect(stable.selections == [NSRange(location: 3, length: 6)])
    try LiveTextEditor.replace(with: "", target: stable)
    #expect(stable.replacements == [""])
    #expect(stable.reads == 2) // Replacement must not read back or echo the supplied value.
}

@Test("Text editing validates the live target before touching an editable field")
@MainActor
func liveTextEditingValidatesBeforeAccess() {
    let target = TextEditingFixture(values: ["private"])
    target.isValid = false
    #expect(throws: RecordingError.self) { try LiveTextEditor.select("private", options: .init(), target: target) }
    #expect(throws: RecordingError.self) { try LiveTextEditor.replace(with: "new", target: target) }
    #expect(target.reads == 0)
    #expect(target.selections.isEmpty)
    #expect(target.replacements.isEmpty)
}

@Test("New text actions validate exact option applicability and keep background editing available")
func liveTextActionContracts() throws {
    let target = PabloLiveApplicationTarget(appName: "Fixture")
    for kind in [PabloLiveActionKind.selectText, .setValue] {
        let request = PabloLiveActionRequest(kind: kind, target: target, nodeID: "field", text: "value")
        try PabloLiveActionValidator.validate(request)
        try LiveActionForegroundPolicy.requireUnlock(for: request)
        #expect(LiveActionSnapshotPolicy.requiresSnapshot(for: request))
    }
    try PabloLiveActionValidator.validate(.init(kind: .setValue, target: target, nodeID: "field", text: ""))
    for invalid in [PabloLiveActionRequest(kind: .selectText, target: target, nodeID: "field", text: ""),
                    .init(kind: .setValue, target: target, text: "value"),
                    .init(kind: .paste, target: target, text: "<b>value</b>", pasteFormat: .html),
                    .init(kind: .paste, target: target, text: "value", plainText: "ignored"),
                    .init(kind: .key, target: target, key: "v", selection: .init())] {
        #expect(throws: RecordingError.self) { try PabloLiveActionValidator.validate(invalid) }
    }
    let paste = PabloLiveActionRequest(kind: .paste, target: target, text: "<b>value</b>", pasteFormat: .html, plainText: "value")
    try PabloLiveActionValidator.validate(paste)
    #expect(throws: RecordingError.self) { try LiveActionForegroundPolicy.requireUnlock(for: paste) }
}

@MainActor
private final class TextEditingFixture: LiveTextEditingTarget {
    let values: [String]
    var reads = 0
    var selections: [NSRange] = []
    var replacements: [String] = []
    var isValid = true
    init(values: [String]) { self.values = values }
    func validate() throws { if !isValid { throw RecordingError.staleContext("Fixture expired") } }
    func readText() throws -> String { defer { reads += 1 }; return values[min(reads, values.count - 1)] }
    func setSelectedRange(_ range: NSRange) throws { selections.append(range) }
    func setValue(_ text: String) throws { replacements.append(text) }
}
