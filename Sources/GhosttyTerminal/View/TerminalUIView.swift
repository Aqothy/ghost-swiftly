#if os(iOS)
import GhosttyVT
import UIKit

/// A UIKit view drawing a ``Terminal`` and sending the user's input to a
/// ``TerminalIO``.
public final class TerminalUIView: UIView, UIKeyInput {
    let surface: TerminalSurface

    public init(terminal: Terminal, io: TerminalIO?, configuration: TerminalConfiguration = .init()) {
        surface = TerminalSurface(terminal: terminal, io: io, configuration: configuration)
        super.init(frame: .zero)
        clipsToBounds = true
        layer.addSublayer(surface.metalLayer)
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _) in
            view.setNeedsLayout()
        }
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
    public var preferredGrid: GridSize? { surface.preferredGrid }

    public override func layoutSubviews() {
        super.layoutSubviews()
        surface.layout(size: bounds.size, scale: Double(traitCollection.displayScale))
    }

    public override var canBecomeFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        surface.setFocused(true)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        surface.setFocused(false)
        return true
    }

    // Keyboard input is minimal until the input layer lands: the software
    // keyboard's text, return and delete.

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        if text == "\n" {
            surface.send(.key(KeyEvent(key: .enter)))
        } else {
            surface.send(.text(text))
        }
    }

    public func deleteBackward() {
        surface.send(.key(KeyEvent(key: .backspace)))
    }

    public var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    public var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }
}
#endif
