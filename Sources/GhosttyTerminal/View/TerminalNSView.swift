// Ported from ghostty macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty macos/Sources/Ghostty/NSEvent+Extension.swift @ 81598385d608dda4946093d6d6a234d204a2f225
// Ported from ghostty macos/Sources/Ghostty/Ghostty.Input.swift @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// Keyboard (keyDown through interpretKeyEvents so input methods work,
// performKeyEquivalent, flagsChanged), NSTextInputClient, mouse and scroll
// input. Without Ghostty's keybindings, key tables, links, Quick Look,
// services, drag and drop or accessibility.

#if os(macOS)
import AppKit
import GhosttyVT

/// An AppKit view drawing a ``Terminal`` and sending the user's input to a
/// ``TerminalIO``.
public final class TerminalNSView: NSView {
    let surface: TerminalSurface
    private var windowObservers: [Task<Void, Never>] = []

    /// Text input methods committed during the current keyDown; nil outside
    /// one.
    private var keyTextAccumulator: [String]?
    /// Uncommitted input method text.
    private var markedText = NSMutableAttributedString()
    /// The timestamp of a Command or Control key equivalent sent back
    /// through AppKit to reach keyDown (see performKeyEquivalent).
    private var lastPerformKeyEvent: TimeInterval?
    /// A UTF-16 lead surrogate waiting for its trail from insertText.
    private var leadSurrogate: UInt16?
    private var lastPressureStage = 0

    public init(terminal: Terminal, io: TerminalIO?, configuration: TerminalConfiguration = .init()) {
        surface = TerminalSurface(terminal: terminal, io: io, configuration: configuration)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(surface.metalLayer)
        surface.clickInterval = .seconds(NSEvent.doubleClickInterval)
        surface.confirmUnsafePaste = { [weak self] text in
            await self?.confirmUnsafePaste(text) ?? false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        windowObservers.forEach { $0.cancel() }
        surface.close()
    }

    public var io: TerminalIO? {
        get { surface.io }
        set { surface.io = newValue }
    }

    public var configuration: TerminalConfiguration {
        get { surface.configuration }
        set { surface.update(newValue) }
    }

    /// The grid that fits this view at its font size.
    public var preferredGrid: GridSize? { surface.preferredGrid }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func layout() {
        super.layout()
        surface.layout(size: bounds.size, scale: Double(window?.backingScaleFactor ?? 2))
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    // MARK: Focus and visibility

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { $0.cancel() }
        windowObservers = []
        if let window {
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ]
            windowObservers = names.map { name in
                Task { [weak self, weak window] in
                    for await _ in NotificationCenter.default.notifications(named: name, object: window) {
                        self?.updateFocus()
                    }
                }
            }
        }
        updateFocus()
    }

    /// Focused is first responder in the key window, as in Ghostty.
    private func updateFocus() {
        guard let window else {
            surface.setFocused(false)
            return
        }
        surface.setFocused(window.isKeyWindow && window.firstResponder === self)
        surface.setVisible(window.occlusionState.contains(.visible))
    }

    public override func becomeFirstResponder() -> Bool {
        // The window's first responder changes after this returns.
        Task { @MainActor in updateFocus() }
        return true
    }

    public override func resignFirstResponder() -> Bool {
        Task { @MainActor in updateFocus() }
        return true
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        let optionAsAlt = configuration.optionAsAlt ?? KeyboardLayout.optionAsAlt

        // Translate with Option removed when it acts as Alt, so Option-f
        // types f rather than ƒ. Hidden bits in the flags matter for dead
        // keys, so only the four modifiers change.
        let translation = Self.translationFlags(event.modifierFlags, optionAsAlt)
        var translationFlags = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translation.contains(flag) {
                translationFlags.insert(flag)
            } else {
                translationFlags.remove(flag)
            }
        }
        // Reuse the original event when nothing changed: Korean input needs
        // the same object.
        let translationEvent = translationFlags == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translationFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: translationFlags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode) ?? event

        let action: KeyEvent.Action = event.isARepeat ? .repeat : .press

        // interpretKeyEvents may commit text through insertText, which
        // collects it here.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        // A key that switches the keyboard layout belongs to the input
        // method, not the terminal.
        let layoutBefore = markedTextBefore ? nil : KeyboardLayout.id
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore, layoutBefore != KeyboardLayout.id { return }

        syncPreedit(clearIfNeeded: markedTextBefore)

        // Composing with preedit, or this key just ended a composition
        // (backspace cancelling Japanese input mustn't delete what came
        // before).
        let composing = markedText.length > 0 || markedTextBefore

        // The input method committed some or all of its text while handling
        // a key that shouldn't itself be encoded: send the text, then only
        // the keys that still mean something.
        if markedTextBefore, let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts where !Self.isComposingControl(text, composing: composing) {
                surface.send(.text(text))
            }
            if Self.shouldReplayCommittedPreeditKey(translationEvent) {
                send(action, event, translationEvent: translationEvent)
            }
            return
        }

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts where !Self.isComposingControl(text, composing: composing) {
                send(action, event, translationEvent: translationEvent, text: text)
            }
        } else {
            // Control characters during composition belong to the input
            // method.
            if Self.isComposingControl(event.characters, composing: composing) { return }
            send(action, event, translationEvent: translationEvent, text: Self.characters(translationEvent),
                 composing: composing)
        }
    }

    public override func keyUp(with event: NSEvent) {
        send(.release, event)
    }

    /// Command and Control keys reach here before keyDown, and AppKit may
    /// turn them into commands (Command-. becomes cancel:) before keyDown.
    /// Returning false lets the menu have them; an unhandled one comes back
    /// through doCommand and is sent again to reach keyDown.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Some, like Control-/, go to the first view in the hierarchy rather
        // than the first responder.
        guard window?.firstResponder === self, window?.isKeyWindow == true else { return false }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Control-Return, which would otherwise open the context menu.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // Control-/ as Control-_, instead of a beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return false }
            equivalent = "_"
        default:
            // Synthetic events (Command-. as Escape) have no timestamp.
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode)
        else { return false }
        keyDown(with: finalEvent)
        return true
    }

    /// Modifier keys pressed and released alone, which the Kitty keyboard
    /// protocol reports.
    public override func flagsChanged(with event: NSEvent) {
        let modifier: Modifiers
        switch event.keyCode {
        case 0x39: modifier = .capsLock
        case 0x38, 0x3C: modifier = .shift
        case 0x3B, 0x3E: modifier = .control
        case 0x3A, 0x3D: modifier = .alt
        case 0x37, 0x36: modifier = .super
        default: return
        }
        if hasMarkedText() { return }

        // Down if held, unless only the other side's key is.
        var action = KeyEvent.Action.release
        if Self.modifiers(event.modifierFlags).contains(modifier) {
            let sidePressed = switch event.keyCode {
            case 0x3C: event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = .press }
        }
        send(action, event)
    }

    private func send(_ action: KeyEvent.Action, _ event: NSEvent, translationEvent: NSEvent? = nil,
                      text: String? = nil, composing: Bool = false) {
        surface.send(.key(Self.keyEvent(event, action: action, translationFlags: translationEvent?.modifierFlags,
                                        text: text, composing: composing)))
    }

    /// Ghostty's `ghosttyKeyEvent`: Control and Command never translate
    /// text, so every other held modifier counts as consumed.
    static func keyEvent(_ event: NSEvent, action: KeyEvent.Action, translationFlags: NSEvent.ModifierFlags?,
                         text: String?, composing: Bool) -> KeyEvent {
        // Without modifiers, rather than charactersIgnoringModifiers,
        // which changes with Control held.
        let unshifted = event.type == .keyDown || event.type == .keyUp
            ? event.characters(byApplyingModifiers: [])?.unicodeScalars.first : nil
        return KeyEvent(
            action: action,
            key: KeyCodes.mac[event.keyCode] ?? .unidentified,
            modifiers: modifiers(event.modifierFlags),
            consumedModifiers: modifiers((translationFlags ?? event.modifierFlags).subtracting([.control, .command])),
            text: text.flatMap(keyEventText) ?? "",
            unshiftedCodepoint: unshifted,
            composing: composing)
    }

    /// The event's text for the key encoder, which does its own control
    /// character mapping: a control character as typed without Control,
    /// and no function key private-use characters.
    static func characters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    /// Text for a key event, or nil when it starts with a control character.
    private static func keyEventText(_ text: String) -> String? {
        guard let scalar = text.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        return text
    }

    /// A lone control character while composing belongs to the input method.
    static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first
        else { return false }
        return scalar.value < 0x20
    }

    /// Arrow keys still move after an input method commits on them; plain
    /// left arrow doesn't, since Korean input methods leave the caret.
    private static func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch KeyCodes.mac[event.keyCode] {
        case .arrowDown, .arrowRight, .arrowUp: true
        case .arrowLeft: !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: false
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
        var modifiers: Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.command) { modifiers.insert(.super) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { modifiers.insert(.rightShift) }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { modifiers.insert(.rightControl) }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { modifiers.insert(.rightAlt) }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { modifiers.insert(.rightSuper) }
        return modifiers
    }

    /// The modifiers that translate a key to text: Option drops out when it
    /// acts as Alt on the side pressed (Ghostty's `Mods.translation`, whose
    /// side is right only when the right key alone is down).
    static func translationFlags(_ flags: NSEvent.ModifierFlags, _ optionAsAlt: OptionAsAlt)
        -> NSEvent.ModifierFlags {
        var result = flags.intersection([.shift, .control, .option, .command])
        guard result.contains(.option) else { return result }
        let rightSide = flags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        let applies = switch optionAsAlt {
        case .none: false
        case .both: true
        case .left: !rightSide
        case .right: rightSide
        }
        if applies { result.remove(.option) }
        return result
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self))
        super.updateTrackingAreas()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    public override func mouseDown(with event: NSEvent) {
        surface.send(.mouseButton(.press, .left, Self.modifiers(event.modifierFlags), point(event), local: nil))
    }

    public override func mouseUp(with event: NSEvent) {
        lastPressureStage = 0
        surface.send(.mouseButton(.release, .left, Self.modifiers(event.modifierFlags), point(event), local: nil))
    }

    /// A right click the program doesn't take opens the context menu.
    public override func rightMouseDown(with event: NSEvent) {
        surface.send(.mouseButton(.press, .right, Self.modifiers(event.modifierFlags), point(event)) { [weak self] in
            guard let self else { return }
            NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
        })
    }

    public override func rightMouseUp(with event: NSEvent) {
        surface.send(.mouseButton(.release, .right, Self.modifiers(event.modifierFlags), point(event), local: nil))
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard let button = Self.button(event.buttonNumber) else { return }
        surface.send(.mouseButton(.press, button, Self.modifiers(event.modifierFlags), point(event), local: nil))
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard let button = Self.button(event.buttonNumber) else { return }
        surface.send(.mouseButton(.release, button, Self.modifiers(event.modifierFlags), point(event), local: nil))
    }

    /// Ghostty's `MouseButton(fromNSEventButtonNumber:)`.
    private static func button(_ number: Int) -> MouseEvent.Button? {
        switch number {
        case 2: .middle
        case 3: .eight
        case 4: .nine
        case 5: .six
        case 6: .seven
        case 7: .four
        case 8: .five
        case 9: .ten
        case 10: .eleven
        default: nil
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        surface.send(.mouseMoved(Self.modifiers(event.modifierFlags), point(event)))
    }

    public override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    public override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        // Drags keep reporting outside the view.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        surface.send(.mouseMoved(Self.modifiers(event.modifierFlags), nil))
    }

    public override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        // Ghostty doubles trackpad deltas: "it feels better".
        let factor = precise ? 2.0 : 1.0
        surface.send(.scroll(x: event.scrollingDeltaX * factor, y: event.scrollingDeltaY * factor, precise: precise))
    }

    /// A force click selects the word under it.
    public override func pressureChange(with event: NSEvent) {
        guard lastPressureStage < 2 else { return }
        lastPressureStage = event.stage
        if event.stage == 2 { surface.send(.deepPress) }
    }

    // MARK: Copy and paste

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        return menu
    }

    @objc public func copy(_ sender: Any?) {
        surface.send(.copy { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        surface.send(.paste(text))
    }

    @objc public override func selectAll(_ sender: Any?) {
        surface.send(.selectAll)
    }

    /// Ghostty's clipboard-paste-protection: text that would run commands
    /// unseen needs the user's go-ahead.
    private func confirmUnsafePaste(_ text: String) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = "Paste text that may run commands?"
        alert.informativeText = String(text.prefix(1000))
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        if markedText.length > 0 {
            surface.setPreedit(markedText.string)
        } else if clearIfNeeded {
            surface.setPreedit(nil)
        }
    }
}

// MARK: NSTextInputClient

extension TerminalNSView: @MainActor NSTextInputClient {
    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    public func selectedRange() -> NSRange {
        NSRange()
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let text as NSAttributedString: markedText = NSMutableAttributedString(attributedString: text)
        case let text as String: markedText = NSMutableAttributedString(string: text)
        default: return
        }
        // Outside a keyDown (a layout change mid-composition), show it now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString? {
        nil
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var rect = surface.cursorRect ?? .zero
        // Dictation's indicator wants an empty rect after the text.
        if range.length == 0, rect.width > 0 {
            rect.origin.x += rect.width
            rect.size.width = 0
        }
        let windowRect = convert(rect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        var text: String
        switch string {
        case let value as NSAttributedString: text = value.string
        case let value as String: text = value
        default: return
        }
        // Some input methods send an emoji's surrogate halves separately.
        let units = Array(text.utf16)
        if units.count == 1, UTF16.isLeadSurrogate(units[0]) {
            leadSurrogate = units[0]
            return
        }
        if units.count == 1, UTF16.isTrailSurrogate(units[0]) {
            guard let lead = leadSurrogate else { return }
            text = String(decoding: [lead, units[0]], as: UTF16.self)
        }
        leadSurrogate = nil

        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        // Committed text (input methods, dictation) is typed, never pasted.
        if !text.isEmpty { surface.send(.text(text)) }
    }

    /// Keeps unhandled commands from beeping, and sends a key equivalent
    /// that AppKit turned into a command back to keyDown.
    public override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}
#endif
