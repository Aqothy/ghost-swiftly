#if os(iOS)
import GhosttyVT
import UIKit

/// A UIKit view drawing a ``Terminal`` and sending the user's input to a
/// ``TerminalIO``.
///
/// Keys come from the software keyboard through UITextInput (with input
/// method composition drawn as Ghostty's preedit), from a hardware keyboard
/// through presses, and from an accessory bar with Escape, Tab, a sticky
/// Control, arrows and a key that hides the keyboard. One finger scrolls, a
/// tap shows the keyboard and, once it's shown, clicks, a long press
/// selects, and a pinch zooms a host grid drawn scaled down.
public final class TerminalUIView: UIView {
    let surface: TerminalSurface
    private var sceneObservers: [Task<Void, Never>] = []

    /// Uncommitted input method text; the UITextInput document while
    /// composing, empty otherwise.
    var markedText = ""
    var markedSelection = NSRange(location: 0, length: 0)
    weak var _inputDelegate: UITextInputDelegate?
    /// A hardware key press was sent, so the insertText or deleteBackward
    /// UIKit sends for the same key is dropped.
    var hardwareKeyHandled = false
    let control = StickyModifier()
    private lazy var accessoryBar = TerminalAccessoryBar(view: self)
    var momentum: CADisplayLink?
    var momentumVelocity = CGPoint.zero
    /// UIKit is moving the keyboard: between its will- and did-change-frame
    /// notifications.
    private var keyboardMoving = false

    public init(terminal: Terminal, io: TerminalIO?, configuration: TerminalConfiguration = .init()) {
        surface = TerminalSurface(terminal: terminal, io: io, configuration: configuration)
        super.init(frame: .zero)
        clipsToBounds = true
        // The terminal draws its own cursor; UIKit's caret anchors the
        // input method only.
        tintColor = .clear
        layer.addSublayer(surface.metalLayer)
        surface.confirmUnsafePaste = { [weak self] text in
            await self?.confirmUnsafePaste(text) ?? false
        }
        control.onChange = { [weak self] in self?.accessoryBar.update() }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _) in
            view.setNeedsLayout()
        }
        setUpGestures()
        // Another field's keyboard moves this view too. Its first step can
        // come before the notification; typing still claims the right size.
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillMove), name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDidMove), name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil)
    }

    /// The keyboard and its accessory bar move in steps, each one a layout;
    /// a host's view reports its grid once they stop rather than at every
    /// step.
    @objc private func keyboardWillMove() {
        keyboardMoving = true
        surface.setSizeSettling(true)
    }

    @objc private func keyboardDidMove() {
        keyboardMoving = false
        surface.setSizeSettling(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        sceneObservers.forEach { $0.cancel() }
        momentum?.invalidate()
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

    // MARK: Focus and visibility

    public override var canBecomeFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        // UIKit swaps the input views inside this call, posting the keyboard
        // notification when the keyboard will move, and none when the
        // accessory bar alone comes back. The grid waits through the call
        // and, after it, only for a move UIKit announced.
        surface.setSizeSettling(true)
        let became = super.becomeFirstResponder()
        surface.setSizeSettling(keyboardMoving)
        guard became else { return false }
        surface.setFocused(true)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        surface.setSizeSettling(true)
        let resigned = super.resignFirstResponder()
        surface.setSizeSettling(keyboardMoving)
        guard resigned else { return false }
        commitMarkedText()
        control.reset()
        surface.setFocused(false)
        return true
    }

    /// iOS ends a background app that draws with the GPU, so drawing stops
    /// while the scene is in the background.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneObservers.forEach { $0.cancel() }
        sceneObservers = []
        guard let scene = window?.windowScene else { return }
        let changes: [(Notification.Name, Bool)] = [
            (UIScene.didEnterBackgroundNotification, false), (UIScene.willEnterForegroundNotification, true),
        ]
        sceneObservers = changes.map { name, visible in
            Task { [weak self, weak scene] in
                for await _ in NotificationCenter.default.notifications(named: name, object: scene) {
                    self?.surface.setVisible(visible)
                }
            }
        }
        surface.setVisible(scene.activationState != .background)
    }

    public override var inputAccessoryView: UIView? { accessoryBar }

    // MARK: Pointer

    /// The button a trackpad or mouse holds down, so its release and drags
    /// report the same one. Finger touches go to the gestures instead.
    private var pointerButton: MouseEvent.Button?

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = Self.pointerTouch(touches), let event else {
            return super.touchesBegan(touches, with: event)
        }
        stopMomentum()
        let button: MouseEvent.Button = event.buttonMask.contains(.secondary) ? .right : .left
        pointerButton = button
        let point = touch.location(in: self)
        // A right click the program doesn't take offers Copy and Paste, as
        // on the Mac.
        surface.send(.mouseButton(.press, button, Self.modifiers(event.modifierFlags), point) { [weak self] in
            guard button == .right, let self else { return }
            let menu = interactions.compactMap { $0 as? UIEditMenuInteraction }.first
            menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        })
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = Self.pointerTouch(touches), pointerButton != nil else {
            return super.touchesMoved(touches, with: event)
        }
        surface.send(.mouseMoved(Self.modifiers(event?.modifierFlags ?? []), touch.location(in: self)))
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = Self.pointerTouch(touches), let button = pointerButton else {
            return super.touchesEnded(touches, with: event)
        }
        pointerButton = nil
        surface.send(.mouseButton(.release, button, Self.modifiers(event?.modifierFlags ?? []),
                                  touch.location(in: self), local: nil))
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = Self.pointerTouch(touches), let button = pointerButton else {
            return super.touchesCancelled(touches, with: event)
        }
        pointerButton = nil
        surface.send(.mouseButton(.release, button, [], touch.location(in: self), local: nil))
    }

    private static func pointerTouch(_ touches: Set<UITouch>) -> UITouch? {
        touches.first { $0.type == .indirectPointer }
    }

    // MARK: Hardware keyboard

    /// Keys whose press this view sent, so their releases go too.
    private var sentKeys: Set<UIKeyboardHIDUsage> = []

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var typed: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, sendsKey(key) else {
                typed.insert(press)
                continue
            }
            sentKeys.insert(key.keyCode)
            // UIKit may still send this key's text or delete; drop it.
            hardwareKeyHandled = true
            hardwareKey(key, action: .press)
        }
        // Plain text keys go through UIKit's text input, so an input method
        // can compose them; they arrive at insertText.
        if !typed.isEmpty { super.pressesBegan(typed, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var typed: Set<UIPress> = []
        for press in presses {
            if let key = press.key, sentKeys.remove(key.keyCode) != nil {
                hardwareKey(key, action: .release)
            } else {
                typed.insert(press)
            }
        }
        // A key UIKit didn't echo mustn't eat later text.
        hardwareKeyHandled = false
        if !typed.isEmpty { super.pressesEnded(typed, with: event) }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key { sentKeys.remove(key.keyCode) }
        }
        hardwareKeyHandled = false
        super.pressesCancelled(presses, with: event)
    }

    /// Whether this view sends the key itself: keys that don't type text
    /// (arrows, Escape, function keys), Tab so Shift-Tab is backtab, and
    /// keys with Control, Command or Option as Alt. While an input method
    /// composes, UIKit owns every key.
    private func sendsKey(_ key: UIKey) -> Bool {
        guard markedText.isEmpty else { return false }
        if key.keyCode == .keyboardDeleteOrBackspace { return !key.modifierFlags.isDisjoint(with: [.control, .alternate]) }
        if key.keyCode == .keyboardTab || key.keyCode == .keyboardEscape { return true }
        if Self.keyText(key.characters) == nil { return true }
        if !key.modifierFlags.isDisjoint(with: [.control, .command]) { return true }
        return key.modifierFlags.contains(.alternate) && (configuration.optionAsAlt ?? .none) != .none
    }

    private func hardwareKey(_ key: UIKey, action: KeyEvent.Action) {
        var flags = key.modifierFlags
        // Function keys carry the numeric pad flag.
        if Self.isFunctionKey(key.characters) || Self.isFunctionKey(key.charactersIgnoringModifiers) {
            flags.remove(.numericPad)
        }
        let modifiers = Self.modifiers(flags)
        let optionAsAlt = (configuration.optionAsAlt ?? .none) != .none && modifiers.contains(.alt)
        // Tab stays a key so Shift-Tab encodes as backtab. With Option as
        // Alt, the text is the key's own, not Option's character.
        let text = action == .release || flags.contains(.command) || key.keyCode == .keyboardTab ? ""
            : Self.keyText(optionAsAlt ? key.charactersIgnoringModifiers : key.characters) ?? ""
        var consumed = modifiers.subtracting([.control, .super])
        if optionAsAlt { consumed.remove(.alt) }
        surface.send(.key(KeyEvent(
            action: action,
            key: KeyCodes.usb[UInt16(key.keyCode.rawValue)] ?? .unidentified,
            modifiers: modifiers,
            consumedModifiers: consumed,
            text: text,
            unshiftedCodepoint: Self.keyText(key.charactersIgnoringModifiers)?.unicodeScalars.first)))
    }

    static func modifiers(_ flags: UIKeyModifierFlags) -> Modifiers {
        var modifiers: Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.alt) }
        if flags.contains(.command) { modifiers.insert(.super) }
        if flags.contains(.alphaShift) { modifiers.insert(.capsLock) }
        return modifiers
    }

    /// UIKit names function keys with private-use characters or names
    /// like `UIKeyInputUpArrow`; neither is text.
    private static func isFunctionKey(_ text: String) -> Bool {
        if text.hasPrefix("UIKeyInput") { return true }
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return (0xF700...0xF8FF).contains(scalar.value)
    }

    /// Key text for the encoder: no function key names and no control
    /// characters, which the encoder makes itself.
    private static func keyText(_ text: String) -> String? {
        guard !text.isEmpty, !isFunctionKey(text), let first = text.unicodeScalars.first,
              first.value >= 0x20, first.value != 0x7F
        else { return nil }
        return text
    }

    // MARK: Typed text

    /// Text from the software keyboard, an input method or the accessory
    /// bar: typed, with a held Control applied.
    func typeText(_ text: String) {
        if control.isActive, let event = Self.controlKeyEvent(text) {
            control.consume()
            surface.send(.key(event))
            return
        }
        surface.send(.text(text))
    }

    /// A single character as the key that types it, with Control, so the
    /// encoder applies the terminal's keyboard modes (taken from
    /// libghostty-spm's accessory key map).
    static func controlKeyEvent(_ text: String) -> KeyEvent? {
        guard text.count == 1, let character = text.first,
              let (key, shift) = keyMap[character] ?? character.lowercased().first.flatMap({ keyMap[$0] })
        else { return nil }
        let shifted = shift || character.isUppercase
        let unshifted = character.isUppercase ? character.lowercased().unicodeScalars.first!
            : unshifted[character] ?? character.unicodeScalars.first!
        return KeyEvent(
            key: key,
            modifiers: shifted ? [.control, .shift] : .control,
            consumedModifiers: shifted ? .shift : [],
            text: text,
            unshiftedCodepoint: unshifted)
    }

    /// A US layout: each character and whether it needs Shift.
    private static let keyMap: [Character: (Key, Bool)] = {
        var map: [Character: (Key, Bool)] = [:]
        let letters: [Key] = [.a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u,
                              .v, .w, .x, .y, .z]
        for (index, key) in letters.enumerated() {
            map[Character(Unicode.Scalar(UInt8(0x61 + index)))] = (key, false)
        }
        let digits: [Key] = [.digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9]
        for (index, key) in digits.enumerated() { map[Character(String(index))] = (key, false) }
        let shiftedDigits = Array(")!@#$%^&*(")
        for (index, character) in shiftedDigits.enumerated() { map[character] = (digits[index], true) }
        let symbols: [(Character, Character, Key)] = [
            ("`", "~", .backquote), ("-", "_", .minus), ("=", "+", .equal), ("[", "{", .bracketLeft),
            ("]", "}", .bracketRight), ("\\", "|", .backslash), (";", ":", .semicolon), ("'", "\"", .quote),
            (",", "<", .comma), (".", ">", .period), ("/", "?", .slash),
        ]
        for (plain, shifted, key) in symbols {
            map[plain] = (key, false)
            map[shifted] = (key, true)
        }
        map[" "] = (.space, false)
        return map
    }()

    /// The unshifted character of each shifted symbol.
    private static let unshifted: [Character: Unicode.Scalar] = {
        let pairs = Array("~`_-+={[}]|\\:;\"'<,>.?/!1@2#3$4%5^6&7*8(9)0")
        var map: [Character: Unicode.Scalar] = [:]
        for index in stride(from: 0, to: pairs.count, by: 2) {
            map[pairs[index]] = pairs[index + 1].unicodeScalars.first!
        }
        return map
    }()

    /// A named key from the accessory bar, with a held Control.
    func sendKey(_ key: Key) {
        commitMarkedText()
        let modifiers: Modifiers = control.isActive ? .control : []
        control.consume()
        surface.send(.key(KeyEvent(key: key, modifiers: modifiers)))
    }

    // MARK: Copy and paste

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)): true
        case #selector(paste(_:)): UIPasteboard.general.hasStrings
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    public override func copy(_ sender: Any?) {
        surface.send(.copy { UIPasteboard.general.string = $0 })
    }

    public override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        commitMarkedText()
        surface.send(.paste(text))
    }

    /// Ghostty's clipboard-paste-protection: text that would run commands
    /// unseen needs the user's go-ahead.
    private func confirmUnsafePaste(_ text: String) async -> Bool {
        guard var presenter = window?.rootViewController else { return false }
        while let presented = presenter.presentedViewController { presenter = presented }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Paste text that may run commands?", message: String(text.prefix(1000)),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Paste", style: .default) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }
}

/// Control on the accessory bar: a tap holds it for the next key, a double
/// tap locks it until tapped again (libghostty-spm's sticky modifiers).
@MainActor
final class StickyModifier {
    enum State {
        case off
        case once
        case locked
    }

    private(set) var state = State.off
    private var lastTap = Date.distantPast
    var onChange: (() -> Void)?

    var isActive: Bool { state != .off }

    func tap() {
        let now = Date()
        state = switch state {
        case .off: .once
        case .once: now.timeIntervalSince(lastTap) < 0.3 ? .locked : .off
        case .locked: .off
        }
        lastTap = now
        onChange?()
    }

    /// A key used it.
    func consume() {
        guard state == .once else { return }
        state = .off
        onChange?()
    }

    func reset() {
        guard state != .off else { return }
        state = .off
        onChange?()
    }
}

/// The keyboard's accessory bar: Escape, Tab, Control, arrows and a key
/// that hides the keyboard.
final class TerminalAccessoryBar: UIInputView {
    private weak var view: TerminalUIView?
    private let controlButton = UIButton(configuration: .gray())
    /// Narrow, so "esc" stays on one line among eight equal keys on an
    /// iPhone.
    private static let keyInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)

    private enum Action {
        case key(Key)
        case control
        case hideKeyboard
    }

    init(view: TerminalUIView) {
        self.view = view
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let keys: [(String, Action)] = [
            ("esc", .key(.escape)), ("tab", .key(.tab)), ("ctrl", .control), ("←", .key(.arrowLeft)),
            ("↑", .key(.arrowUp)), ("↓", .key(.arrowDown)), ("→", .key(.arrowRight)),
            ("Hide Keyboard", .hideKeyboard),
        ]
        let buttons = keys.map { title, action -> UIButton in
            let button = if case .control = action { controlButton } else { UIButton(configuration: .gray()) }
            if case .hideKeyboard = action {
                button.configuration?.image = UIImage(systemName: "keyboard.chevron.compact.down")
                button.accessibilityLabel = title
            } else {
                button.configuration?.title = title
            }
            button.configuration?.contentInsets = Self.keyInsets
            button.addAction(UIAction { [weak self] _ in
                guard let view = self?.view else { return }
                switch action {
                case .key(let key): view.sendKey(key)
                case .control: view.control.tap()
                case .hideKeyboard: _ = view.resignFirstResponder()
                }
            }, for: .touchUpInside)
            return button
        }
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        let state = view?.control.state ?? .off
        controlButton.configuration = state == .off ? .gray() : state == .once ? .tinted() : .filled()
        controlButton.configuration?.title = "ctrl"
        controlButton.configuration?.contentInsets = Self.keyInsets
    }
}
#endif
