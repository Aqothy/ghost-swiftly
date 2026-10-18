import GhosttyVT

/// How a view looks and behaves. Defaults are Ghostty's.
public struct TerminalConfiguration: Sendable, Equatable {
    public var font = Font()
    public var theme = Theme()
    public var gridPolicy = GridPolicy.fitView
    /// How the Option key types (Ghostty's `macos-option-as-alt`).
    public var optionAsAlt = OptionAsAlt.none
    /// Space around the grid, in points (Ghostty's `window-padding-x/y`).
    public var padding = 2.0

    public init() {}

    public struct Font: Sendable, Equatable {
        /// A font family installed on the system; nil for the bundled
        /// JetBrains Mono. Symbols Nerd Font and Apple Color Emoji always
        /// fill in what it lacks.
        public var family: String?
        /// Points (Ghostty's `font-size`: 13 on macOS, 12 elsewhere).
        public var size: Double

        public init(family: String? = nil, size: Double? = nil) {
            self.family = family
            #if os(macOS)
            self.size = size ?? 13
            #else
            self.size = size ?? 12
            #endif
        }
    }

    public struct Theme: Sendable, Equatable {
        public var foreground = RGB(0xFFFFFF)
        public var background = RGB(0x282C34)
        /// Nil uses the foreground.
        public var cursor: RGB?
        /// The text under a block cursor; nil uses the background.
        public var cursorText: RGB?
        /// Nil uses the foreground.
        public var selectionBackground: RGB?
        /// Nil uses the background.
        public var selectionForeground: RGB?
        /// Overrides of the 256-color palette, by index.
        public var palette: [UInt8: RGB] = [:]

        public init() {}
    }

    /// Whose grid the view draws.
    public enum GridPolicy: Sendable, Equatable {
        /// The view's grid is the program's: a local PTY or SSH. The view
        /// resizes its terminal to fit and tells the I/O.
        case fitView
        /// A remote host owns the grid. The view draws the host's grid,
        /// scaled down when it doesn't fit, and asks the host to resize to
        /// its own grid only when the user types into it (or its fit changes
        /// while it holds the size).
        case host
    }
}
