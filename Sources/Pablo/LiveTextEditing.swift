import ApplicationServices
import Foundation

public struct PabloLiveTextRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int
}

public struct PabloLiveTextSelection: Codable, Equatable, Sendable {
    public enum SelectionType: String, Codable, Sendable { case text, cursorBefore, cursorAfter }
    public let prefix: String?
    public let suffix: String?
    public let selectionType: SelectionType

    public init(prefix: String? = nil, suffix: String? = nil, selectionType: SelectionType = .text) {
        self.prefix = prefix
        self.suffix = suffix
        self.selectionType = selectionType
    }

    func validate() throws {
        guard [prefix, suffix].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }) else {
            throw RecordingError.usage("Text selection context must be nonempty and at most 4 KiB per side.")
        }
    }

    private enum CodingKeys: String, CodingKey { case prefix, suffix, selectionType }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(prefix: try values.decodeIfPresent(String.self, forKey: .prefix),
                  suffix: try values.decodeIfPresent(String.self, forKey: .suffix),
                  selectionType: try values.decodeIfPresent(SelectionType.self, forKey: .selectionType) ?? .text)
    }
}

enum LiveTextSelectionRange {
    static func resolve(text: String, in content: String, options: PabloLiveTextSelection) throws -> NSRange {
        try options.validate()
        guard !text.isEmpty, text.utf8.count <= 32 * 1_024, content.utf16.count <= 2_000_000 else {
            throw RecordingError.usage("Text selection requires a nonempty phrase and a bounded editable value.")
        }
        let source = content as NSString
        let prefix = options.prefix as NSString?
        let suffix = options.suffix as NSString?
        var start = 0
        var match: NSRange?
        while start < source.length {
            let range = source.range(of: text, options: .literal, range: NSRange(location: start, length: source.length - start))
            if range.location == NSNotFound { break }
            let prefixMatches = prefix.map {
                range.location >= $0.length && source.substring(with: NSRange(location: range.location - $0.length, length: $0.length)) == $0 as String
            } ?? true
            let suffixMatches = suffix.map {
                NSMaxRange(range) + $0.length <= source.length && source.substring(with: NSRange(location: NSMaxRange(range), length: $0.length)) == $0 as String
            } ?? true
            if prefixMatches && suffixMatches {
                guard match == nil else {
                    throw RecordingError.usage("The phrase matches more than once. Supply adjacent prefix or suffix text to select one occurrence.")
                }
                match = range
            }
            start = range.location + 1
        }
        guard let match else { throw RecordingError.staleContext("The phrase and surrounding context do not match the current field value.") }
        switch options.selectionType {
        case .text: return match
        case .cursorBefore: return NSRange(location: match.location, length: 0)
        case .cursorAfter: return NSRange(location: NSMaxRange(match), length: 0)
        }
    }
}

@MainActor
protocol LiveTextEditingTarget {
    func validate() throws
    func readText() throws -> String
    func setSelectedRange(_ range: NSRange) throws
    func setValue(_ text: String) throws
}

@MainActor
enum LiveTextEditor {
    static func select(_ text: String, options: PabloLiveTextSelection, target: any LiveTextEditingTarget) throws {
        try target.validate()
        let original = try target.readText()
        let range = try LiveTextSelectionRange.resolve(text: text, in: original, options: options)
        try target.validate()
        guard try target.readText() == original else {
            throw RecordingError.staleContext("The editable value changed while locating the phrase. Observe it again before selecting text.")
        }
        try target.setSelectedRange(range)
    }

    static func replace(with text: String, target: any LiveTextEditingTarget) throws {
        try target.validate()
        try target.setValue(text)
    }
}

@MainActor
struct NativeLiveTextEditingTarget: LiveTextEditingTarget {
    let reader: AccessibilityTreeReader
    let nodeID: String
    let windowID: String?
    let validateContext: () throws -> Void

    func validate() throws {
        try Task.checkCancellation()
        try validateContext()
        _ = try element()
    }

    private func element() throws -> AXUIElement {
        guard let element = reader.validatedElement(id: nodeID, windowID: windowID) else {
            throw RecordingError.staleContext("The selected editable node is no longer available.")
        }
        let role = attribute(element, kAXRoleAttribute) as? String
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? ""),
              attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else {
            throw RecordingError.usage("Precise text editing requires a non-secure editable text control.")
        }
        guard attribute(element, kAXEnabledAttribute) as? Bool != false else {
            throw RecordingError.usage("The selected editable control is disabled.")
        }
        return element
    }

    func readText() throws -> String {
        guard let value = attribute(try element(), kAXValueAttribute) as? String,
              value.utf16.count <= 2_000_000 else {
            throw RecordingError.usage("The selected control does not expose a bounded editable text value.")
        }
        return value
    }

    func setSelectedRange(_ range: NSRange) throws {
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range) else {
            throw RecordingError.capture("Could not represent the text selection range.")
        }
        try set(kAXSelectedTextRangeAttribute, value: value)
    }

    func setValue(_ text: String) throws { try set(kAXValueAttribute, value: text as CFString) }

    private func set(_ name: String, value: CFTypeRef) throws {
        try validate()
        let element = try element()
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success, settable.boolValue else {
            throw RecordingError.usage("The selected control does not support the requested editable attribute.")
        }
        guard AXUIElementSetAttributeValue(element, name as CFString, value) == .success else {
            throw RecordingError.capture("The selected control rejected the text edit.")
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
