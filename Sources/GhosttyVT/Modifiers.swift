import GhosttyVt

/// Modifier keys held during a key or mouse event.
public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let shift = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    public static let control = Modifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    public static let alt = Modifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
    public static let `super` = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
    public static let capsLock = Modifiers(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
    public static let numLock = Modifiers(rawValue: UInt16(GHOSTTY_MODS_NUM_LOCK))
    /// Set with `.shift` when it is the right-hand key.
    public static let rightShift = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT_SIDE))
    /// Set with `.control` when it is the right-hand key.
    public static let rightControl = Modifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL_SIDE))
    /// Set with `.alt` when it is the right-hand key. Option-as-alt for one
    /// side reads this.
    public static let rightAlt = Modifiers(rawValue: UInt16(GHOSTTY_MODS_ALT_SIDE))
    /// Set with `.super` when it is the right-hand key.
    public static let rightSuper = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER_SIDE))
}
