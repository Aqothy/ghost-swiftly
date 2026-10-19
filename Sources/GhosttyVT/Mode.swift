import GhosttyVt

/// A terminal mode, set by the program with SM/RM (ANSI) or DECSET/DECRST.
public struct Mode: Sendable, Hashable {
    let ghostty: GhosttyMode

    /// A DEC private mode (`CSI ? n h`).
    public init(dec value: UInt16) {
        ghostty = ghostty_mode_new(value, false)
    }

    /// An ANSI mode (`CSI n h`).
    public init(ansi value: UInt16) {
        ghostty = ghostty_mode_new(value, true)
    }

    public static let cursorKeys = Mode(dec: 1)
    public static let cursorBlinking = Mode(dec: 12)
    public static let cursorVisible = Mode(dec: 25)
    public static let focusEvents = Mode(dec: 1004)
    public static let alternateScroll = Mode(dec: 1007)
    public static let alternateScreen = Mode(dec: 1049)
    public static let bracketedPaste = Mode(dec: 2004)
    public static let synchronizedOutput = Mode(dec: 2026)
    public static let graphemeCluster = Mode(dec: 2027)
}
