#if os(iOS)
import GhosttyVT
import UIKit

/// A position in the marked text, in UTF-16 units.
final class TextPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }
}

final class TextRange: UITextRange {
    let range: NSRange

    init(_ range: NSRange) {
        self.range = range
    }

    override var start: UITextPosition { TextPosition(range.location) }
    override var end: UITextPosition { TextPosition(range.location + range.length) }
    override var isEmpty: Bool { range.length == 0 }
}

/// The text document UIKit edits is only the input method's marked text;
/// everything committed goes to the program (as in libghostty-spm).
extension TerminalUIView: @MainActor UITextInput {
    // MARK: Traits

    public var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    public var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    public var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    public var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }

    public var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
    }

    public var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    /// Inline predictions arrive as marked text and would span the cursor.
    public var inlinePredictionType: UITextInlinePredictionType {
        get { .no }
        set {}
    }

    // MARK: UIKeyInput

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        // The hardware key that typed this was already sent.
        if hardwareKeyHandled {
            hardwareKeyHandled = false
            return
        }
        clearMarkedText()
        // Software keyboards commit Return as LF or CRLF; a terminal's Enter
        // is CR (libghostty-spm b1fc9d7).
        switch text {
        case "\n", "\r\n": sendKey(.enter)
        default: typeText(text)
        }
    }

    public func deleteBackward() {
        if !markedText.isEmpty {
            updateMarkedText {
                let text = NSMutableString(string: markedText)
                if markedSelection.length > 0 {
                    text.deleteCharacters(in: markedSelection)
                } else if markedSelection.location > 0 {
                    text.deleteCharacters(in: NSRange(location: markedSelection.location - 1, length: 1))
                    markedSelection.location -= 1
                }
                markedSelection.length = 0
                markedText = text as String
            }
            return
        }
        if hardwareKeyHandled {
            hardwareKeyHandled = false
            return
        }
        sendKey(.backspace)
    }

    // MARK: Marked text

    public func setMarkedText(_ text: String?, selectedRange: NSRange) {
        let text = text ?? ""
        // With Control held, the first composed character is a control key.
        if control.isActive, let first = text.first {
            clearMarkedText()
            typeText(String(first))
            return
        }
        updateMarkedText {
            markedText = text
            let length = text.utf16.count
            let location = min(max(0, selectedRange.location), length)
            markedSelection = NSRange(location: location, length: min(selectedRange.length, length - location))
        }
    }

    public func unmarkText() {
        let text = markedText
        clearMarkedText()
        if !text.isEmpty { typeText(text) }
    }

    /// Commits what's being composed, before a key that isn't part of it.
    func commitMarkedText() {
        guard !markedText.isEmpty else { return }
        _inputDelegate?.textWillChange(self)
        unmarkText()
        _inputDelegate?.textDidChange(self)
    }

    private func clearMarkedText() {
        guard !markedText.isEmpty else { return }
        updateMarkedText {
            markedText = ""
            markedSelection = NSRange(location: 0, length: 0)
        }
    }

    private func updateMarkedText(_ change: () -> Void) {
        _inputDelegate?.textWillChange(self)
        _inputDelegate?.selectionWillChange(self)
        change()
        surface.setPreedit(markedText)
        _inputDelegate?.selectionDidChange(self)
        _inputDelegate?.textDidChange(self)
    }

    public var markedTextRange: UITextRange? {
        markedText.isEmpty ? nil : TextRange(NSRange(location: 0, length: markedText.utf16.count))
    }

    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    public var selectedTextRange: UITextRange? {
        get { TextRange(markedSelection) }
        set {
            guard let range = (newValue as? TextRange)?.range else { return }
            let length = markedText.utf16.count
            let location = min(max(0, range.location), length)
            markedSelection = NSRange(location: location, length: min(max(0, range.length), length - location))
        }
    }

    // MARK: Document

    public func text(in range: UITextRange) -> String? {
        guard let range = (range as? TextRange)?.range else { return nil }
        let text = markedText as NSString
        guard range.location >= 0, range.location + range.length <= text.length else { return nil }
        return text.substring(with: range)
    }

    /// Some keyboards commit Return here rather than through insertText.
    public func replace(_ range: UITextRange, withText text: String) {
        insertText(text)
    }

    public var beginningOfDocument: UITextPosition { TextPosition(0) }
    public var endOfDocument: UITextPosition { TextPosition(markedText.utf16.count) }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = (fromPosition as? TextPosition)?.offset, let to = (toPosition as? TextPosition)?.offset
        else { return nil }
        return TextRange(NSRange(location: min(from, to), length: abs(to - from)))
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let start = (position as? TextPosition)?.offset else { return nil }
        let offset = start + offset
        return (0...markedText.utf16.count).contains(offset) ? TextPosition(offset) : nil
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int)
        -> UITextPosition? {
        self.position(from: position, offset: direction == .left || direction == .up ? -offset : offset)
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let lhs = (position as? TextPosition)?.offset ?? 0
        let rhs = (other as? TextPosition)?.offset ?? 0
        return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? TextPosition)?.offset ?? 0) - ((from as? TextPosition)?.offset ?? 0)
    }

    public var inputDelegate: UITextInputDelegate? {
        get { _inputDelegate }
        set { _inputDelegate = newValue }
    }

    public var tokenizer: UITextInputTokenizer { UITextInputStringTokenizer(textInput: self) }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left || direction == .up ? range.start : range.end
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection)
        -> UITextRange? {
        guard let offset = (position as? TextPosition)?.offset else { return nil }
        return TextRange(NSRange(location: offset, length: 0))
    }

    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection)
        -> NSWritingDirection {
        .leftToRight
    }

    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: Geometry, for the input method's candidates

    public func firstRect(for range: UITextRange) -> CGRect {
        surface.cursorRect ?? .zero
    }

    /// Zero wide: the terminal draws the cursor.
    public func caretRect(for position: UITextPosition) -> CGRect {
        var rect = surface.cursorRect ?? .zero
        if let offset = (position as? TextPosition)?.offset, !markedText.isEmpty {
            rect.origin.x += rect.width * Double(offset) / Double(markedText.utf16.count)
        } else {
            rect.origin.x += rect.width
        }
        rect.size.width = 0
        return rect
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        []
    }

    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        TextPosition(markedText.utf16.count)
    }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        range.end
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
        TextRange(NSRange(location: markedText.utf16.count, length: 0))
    }
}
#endif
