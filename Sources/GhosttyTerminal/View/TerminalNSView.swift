#if os(macOS)
import AppKit
import GhosttyVT

/// An AppKit view drawing a ``Terminal`` and sending the user's input to a
/// ``TerminalIO``.
public final class TerminalNSView: NSView {
    let surface: TerminalSurface

    public init(terminal: Terminal, io: TerminalIO?, configuration: TerminalConfiguration = .init()) {
        surface = TerminalSurface(terminal: terminal, io: io, configuration: configuration)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(surface.metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
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
    public var preferredGrid: Grid? { surface.preferredGrid }

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

    public override func becomeFirstResponder() -> Bool {
        surface.setFocused(true)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        surface.setFocused(false)
        return true
    }

    // Keyboard input is minimal until the input layer lands: no IME, no
    // dead keys.
    public override func keyDown(with event: NSEvent) {
        surface.send(.key(Self.keyEvent(event, action: event.isARepeat ? .repeat : .press)))
    }

    public override func keyUp(with event: NSEvent) {
        surface.send(.key(Self.keyEvent(event, action: .release)))
    }

    static func keyEvent(_ event: NSEvent, action: KeyEvent.Action) -> KeyEvent {
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.command) { modifiers.insert(.super) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        // Function keys' private-use characters and control characters
        // aren't text.
        let characters = event.characters ?? ""
        let text = characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) }
            ? characters : ""
        let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
        return KeyEvent(
            action: action,
            key: KeyCodes.mac[event.keyCode] ?? .unidentified,
            modifiers: modifiers,
            consumedModifiers: modifiers.intersection([.shift, .alt]),
            text: text,
            unshiftedCodepoint: unshifted)
    }
}
#endif
