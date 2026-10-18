import GhosttyVt

/// One key press, repeat or release, as the platform reported it.
public struct KeyEvent: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case press
        case `repeat`
        case release
    }

    public var action: Action
    public var key: Key
    public var modifiers: Modifiers
    /// Modifiers the platform used up producing `text` (for example shift for
    /// "A"), so the encoder doesn't report them again.
    public var consumedModifiers: Modifiers
    /// The text the key produced, empty for keys that produce none.
    public var text: String
    /// The key's character with no modifiers applied, for the Kitty protocol's
    /// base layout key.
    public var unshiftedCodepoint: Unicode.Scalar?
    /// True while an input method is composing; the encoder then sends nothing
    /// for the text.
    public var composing: Bool

    public init(
        action: Action = .press,
        key: Key,
        modifiers: Modifiers = [],
        consumedModifiers: Modifiers = [],
        text: String = "",
        unshiftedCodepoint: Unicode.Scalar? = nil,
        composing: Bool = false
    ) {
        self.action = action
        self.key = key
        self.modifiers = modifiers
        self.consumedModifiers = consumedModifiers
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
        self.composing = composing
    }
}

/// How the macOS Option key is encoded (Ghostty's `macos-option-as-alt`).
public enum OptionAsAlt: Sendable, Hashable {
    /// Option composes characters, as in other macOS apps.
    case none
    case both
    case left
    case right

    var ghostty: GhosttyOptionAsAlt {
        switch self {
        case .none: GHOSTTY_OPTION_AS_ALT_FALSE
        case .both: GHOSTTY_OPTION_AS_ALT_TRUE
        case .left: GHOSTTY_OPTION_AS_ALT_LEFT
        case .right: GHOSTTY_OPTION_AS_ALT_RIGHT
        }
    }
}
